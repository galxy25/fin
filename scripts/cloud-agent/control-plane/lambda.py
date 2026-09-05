"""Fin cloud-worker control plane: one Lambda behind an API Gateway HTTP API.

A "worker" is one EC2 instance hosting one fin-agentd harness, launched with the
bootstrap scripts/cloud-agent/launch.sh defines: AL2023 arm64 from the SSM alias,
the egress-only security group, the SSM-only instance profile, IMDSv2 required,
and a boot fetch of the binary and per-agent config over presigned S3 URLs. The
instance role still holds no S3 permission of its own — every S3 capability the
agent gets is a presigned URL signed here, by the Lambda role, with an expiry.

Two invocation shapes reach the handler: an HTTP API payload-v2 request, which
must carry `authorization: Bearer $FIN_CP_TOKEN`, and a direct EventBridge invoke
`{"source": "sweep-schedule"}`, which carries no headers and is authorized by the
invoke permission on the function instead.

The bearer token must never reach a log line or a response body, and presigned
URLs must never be logged; error strings are truncated and scrubbed of SigV4
query parameters. The one deliberate exception is `POST /presign`, whose whole
purpose is to hand freshly signed URLs back to an authenticated caller in the
response body — so it returns them plainly (never through `_scrub`) and still
never logs them.

Push notifications close the loop from a headless agent back to a human:
`PUT /device-tokens` stores the APNs token the app registers on every launch,
and `POST /notify` fans one alert out to every stored token over APNs' HTTP/2
API. The APNs auth key (`APNS_KEY`) and the ES256 provider JWT minted from it
are credentials exactly like the bearer token: never logged, never echoed in a
response body. Deployed without the APNS_* environment, `/notify` answers 503
and every other route is unaffected.

The service-credential store under Secrets Manager `fin/service-creds/*` is
WRITE-ONLY from here: no route ever returns a secret value, no handler logs one
(the PUT body's credential fields must never reach a log line or an ApiError
message), and the Lambda role deliberately holds no secretsmanager:GetSecretValue
— the read path belongs to the worker instance role alone, so even a code
regression in this file cannot leak a value through the API.
"""

import base64
import hashlib
import hmac
import json
import logging
import os
import re
import time
import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

REGION = "us-west-2"
BUCKET = "fin-agent-directives-011183829623"
BINARY_KEY = "fin/agentd/fin-agentd"
CONFIG_KEY = "fin/agentd/{agent}.json"
STATUS_KEY = "fin/status-{agent}.json"
INBOX_KEY = "fin/inbox/{agent}.json"
TRANSCRIPT_KEY = "fin/transcripts/{agent}.jsonl"

# Auto-provisioning: when POST /workers finds no config for an agent, it
# instantiates this template — the hand-provisioned config shape with every
# per-agent value replaced by a {{PLACEHOLDER}} token. The operator generates it
# from a live config with scripts/cloud-agent/make-config-template.sh (S3 to S3,
# so the shared LLM bearer token inside never lands in git).
TEMPLATE_KEY = "fin/agentd/_template.json"

# Presign lifetime for the supervision/transcript URLs baked into an
# auto-provisioned config: the SigV4 maximum. The stated week is an upper bound,
# not a promise — these are signed with the Lambda role's temporary credentials
# and die with them (hours), unlike the operator-minted URLs in a
# hand-provisioned config. See "Auto-provisioning" in control-plane/README.md.
TEMPLATE_URL_TTL_SECONDS = 7 * 24 * 3600

# The app-wide supervision channel: two objects with no agent slug — the directive
# document the app reads and the supervision status the app writes back.
SUPERVISION_DIRECTIVE_KEY = "fin/directives.json"
SUPERVISION_STATUS_KEY = "fin/status.json"


def _key_slug(agent):
    """S3 keys use the lowercased agent name — the display name keeps its case
    ("Nimbus") but every object the tooling mints is lowercase ("nimbus.json"),
    and S3 keys are case-sensitive."""
    return agent.lower()

TABLE_NAME = os.environ.get("FIN_CP_TABLE", "fin-cloud-workers")
# Its own table, not an item-type in fin-cloud-workers: that table's rows ARE
# workers (list_workers scans it whole), so a foreign item shape there would
# leak into every worker listing. The token is the hash key — dedupe by design.
DEVICE_TOKENS_TABLE_NAME = os.environ.get("FIN_CP_DEVICE_TOKENS_TABLE", "fin-device-tokens")
SECURITY_GROUP_NAME = "fin-agent-egress"
INSTANCE_PROFILE_NAME = "fin-agent-ssm"
AMI_PARAMETER = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"

DEFAULT_INSTANCE_TYPE = "t4g.nano"
DEFAULT_IDLE_MINUTES = 30
MAX_IDLE_MINUTES = 24 * 60

# A worker whose status object never appears is only swept after this long: the
# instance may still be installing packages and fetching the binary.
BOOT_GRACE_MINUTES = 45

# The instance fetches binary and config once, at boot. An hour is generous for
# that, and these URLs are signed with the Lambda's temporary credentials, so
# they die with the credentials even if the stated expiry has not passed.
PRESIGN_TTL_SECONDS = 3600

# Estimated us-west-2 on-demand rates, hardcoded so /usage needs no Pricing API
# call. These exist to calibrate subscription pricing and are NOT billing truth:
# they ignore Savings Plans, Spot, EBS, data transfer, and free-tier credit.
PRICE_USD_PER_HOUR = {
    "t4g.nano": 0.0042,
    "t4g.micro": 0.0084,
    "t4g.small": 0.0168,
    "t4g.medium": 0.0336,
}

# States in which the harness is holding an instance open without doing work.
IDLE_STATES = ("idle", "task-complete")

# The agent name lands in an S3 key and an EC2 tag value, so it is restricted to
# characters that can do neither key traversal nor tag-filter surprises.
AGENT_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")

# --- service-credential store (Secrets Manager) ------------------------------
# Secrets live at fin/service-creds/<agentScope>/<service>. The scope is the
# agent's key slug (lowercased display name), or the reserved scope "shared",
# which every worker may read — and which POST /workers refuses as an agent
# name so the two can never collide.
SECRET_PREFIX = "fin/service-creds"
SECRET_SCOPE_SHARED = "shared"
SERVICE_NAME = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
SECRET_KINDS = ("app-password", "oauth", "api-key", "password")
SECRET_RECOVERY_DAYS = 7
MAX_SECRET_FIELD_BYTES = 4 * 1024
MAX_SECRET_BYTES = 64 * 1024  # the Secrets Manager hard limit

# Browser workers get chromium + playwright at boot; chromium in nano/micro's
# 0.5–1 GiB dies on memory and bills for nothing, so refuse before spending —
# the same logic as the config head-check.
BROWSER_MIN_INSTANCE_TYPE = "t4g.small"

# Reads are capped rather than paginated to exhaustion: one item per worker ever
# launched keeps this table in the hundreds, which is also why a Scan beats
# maintaining a GSI here.
MAX_SCAN_ITEMS = 5000
MAX_LIST_ITEMS = 100

_SESSION = boto3.session.Session(region_name=REGION)
EC2 = _SESSION.client("ec2")
SSM = _SESSION.client("ssm")
S3 = _SESSION.client("s3", config=Config(signature_version="s3v4"))
SECRETS = _SESSION.client("secretsmanager")
_DYNAMODB = _SESSION.resource("dynamodb")
TABLE = _DYNAMODB.Table(TABLE_NAME)
DEVICE_TOKENS_TABLE = _DYNAMODB.Table(DEVICE_TOKENS_TABLE_NAME)

# Byte-for-byte the bootstrap from launch.sh; the two presigned URLs are the only
# substitutions. Any change to launch.sh's user-data belongs here too.
USER_DATA = """#!/bin/bash
set -euxo pipefail
# NOT libcurl: AL2023 preinstalls libcurl-minimal, which provides libcurl.so.4
# (all the Swift binary needs) and CONFLICTS with the full package — installing
# it fails dnf and, under set -e, kills this whole bootstrap.
dnf install -y tmux openssh-server
systemctl enable --now sshd

# The agent's sandbox: the daemon SSHes to localhost as fin-agent.
useradd -m fin-agent || true
sudo -u fin-agent ssh-keygen -t ed25519 -N "" -f /home/fin-agent/.ssh/id_ed25519 || true
sudo -u fin-agent bash -c 'cat /home/fin-agent/.ssh/id_ed25519.pub >> /home/fin-agent/.ssh/authorized_keys && chmod 600 /home/fin-agent/.ssh/authorized_keys'

mkdir -p /opt/fin-agentd
curl -fsSL -o /opt/fin-agentd/fin-agentd '{binary_url}'
curl -fsSL -o /opt/fin-agentd/config.json '{config_url}'
chmod +x /opt/fin-agentd/fin-agentd
chown -R fin-agent:fin-agent /opt/fin-agentd

cat > /etc/systemd/system/fin-agentd.service <<'UNIT'
[Unit]
Description=fin cloud agent harness
After=network-online.target sshd.service
Wants=network-online.target

[Service]
User=fin-agent
WorkingDirectory=/opt/fin-agentd
ExecStart=/opt/fin-agentd/fin-agentd /opt/fin-agentd/config.json
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now fin-agentd
"""

# Byte-for-byte the optional browser block from launch.sh (same doctrine as
# USER_DATA above). Appended AFTER .format() runs — it must stay out of the
# template so nothing here is treated as a placeholder — and after the harness
# is enabled, so the chromium download never delays the status object the
# sweep's boot grace waits on.
BROWSER_USER_DATA = """
# --- headless browser (playwright + chromium) --------------------------------
# Idempotent: dnf and pip skip what is already present; playwright install is a
# no-op once the pinned chromium build is cached under ~fin-agent.
dnf install -y python3 python3-pip \\
  alsa-lib at-spi2-atk at-spi2-core atk cairo cups-libs dbus-libs expat glib2 \\
  libdrm libX11 libXcomposite libXdamage libXext libXfixes libXrandr libxcb \\
  libxkbcommon mesa-libgbm nspr nss pango liberation-fonts
sudo -u fin-agent -H python3 -m pip install --user --quiet playwright
sudo -u fin-agent -H python3 -m playwright install chromium

# Boot-time smoke: mirrors scripts/cloud-agent/browser-smoke.py (keep in sync).
# Failure lands in cloud-init-output.log and is never fatal to the boot.
sudo -u fin-agent -H python3 - <<'PYSMOKE' || echo 'BROWSER SMOKE FAILED'
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page()
    page.goto("https://example.com", wait_until="load", timeout=30000)
    assert "Example Domain" in page.title()
    browser.close()
print("BROWSER SMOKE OK")
PYSMOKE
"""


class ApiError(Exception):
    """An error with a chosen HTTP status; the message is returned to the caller."""

    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


# --- helpers -----------------------------------------------------------------


def _now():
    return datetime.now(timezone.utc)


def _iso(when):
    return when.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_iso(text):
    """Parses the daemon's and this Lambda's ISO8601 stamps; None on anything else."""
    if not isinstance(text, str) or not text.strip():
        return None
    raw = text.strip()
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    try:
        when = datetime.fromisoformat(raw)
    except ValueError:
        return None
    return when if when.tzinfo else when.replace(tzinfo=timezone.utc)


def _scrub(text):
    """Truncates an error string and drops anything carrying a SigV4 signature."""
    text = str(text)[:300]
    return "[redacted]" if "X-Amz-" in text else text


def _json_default(value):
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    raise TypeError("not JSON serializable: {}".format(type(value).__name__))


def _response(status, payload):
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(payload, default=_json_default),
    }


def _header(event, name):
    for key, value in (event.get("headers") or {}).items():
        if key.lower() == name:
            return value or ""
    return ""


def _authorize(event):
    expected = os.environ.get("FIN_CP_TOKEN") or ""
    if not expected:
        raise ApiError(500, "control plane token is not configured")
    presented = _header(event, "authorization").strip()
    scheme, _, token = presented.partition(" ")
    if scheme.lower() != "bearer" or not hmac.compare_digest(token.strip().encode(), expected.encode()):
        raise ApiError(401, "unauthorized")


def _body(event):
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8", "replace")
    if not raw.strip():
        return {}
    try:
        parsed = json.loads(raw)
    except ValueError:
        raise ApiError(400, "body is not valid JSON")
    if not isinstance(parsed, dict):
        raise ApiError(400, "body must be a JSON object")
    return parsed


# --- worker records ----------------------------------------------------------


def _scan(table=None, **kwargs):
    table = TABLE if table is None else table
    items, start = [], None
    while len(items) < MAX_SCAN_ITEMS:
        if start:
            kwargs["ExclusiveStartKey"] = start
        page = table.scan(**kwargs)
        items.extend(page.get("Items", []))
        start = page.get("LastEvaluatedKey")
        if not start:
            break
    return items


def _live_workers():
    return _scan(
        FilterExpression="#s = :live",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":live": "live"},
    )


def _record(worker_id, agent, instance_id, instance_type, launched_at, idle_minutes, managed, browser=False):
    item = {
        "workerId": worker_id,
        "agent": agent,
        "instanceId": instance_id,
        "instanceType": instance_type,
        "launchedAt": launched_at,
        "idleMinutes": int(idle_minutes),
        "status": "live",
        "managed": managed,
        "browser": bool(browser),
    }
    TABLE.put_item(Item=item)
    return item


def _terminate(worker, reason):
    """Terminates the instance and stamps the record; already-gone instances are fine."""
    instance_id = worker.get("instanceId")
    if instance_id:
        try:
            EC2.terminate_instances(InstanceIds=[instance_id])
        except ClientError as exc:
            code = exc.response.get("Error", {}).get("Code", "")
            if code not in ("InvalidInstanceID.NotFound", "InvalidInstanceID.Malformed"):
                raise
    stamped = _iso(_now())
    TABLE.update_item(
        Key={"workerId": worker["workerId"]},
        UpdateExpression="SET #s = :dead, terminatedAt = :at, terminatedReason = :reason",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":dead": "terminated", ":at": stamped, ":reason": reason},
    )
    final = dict(worker)
    final.update(status="terminated", terminatedAt=stamped, terminatedReason=reason)
    return final


def _uptime_seconds(worker, now):
    started = _parse_iso(worker.get("launchedAt"))
    if not started:
        return 0
    ended = _parse_iso(worker.get("terminatedAt")) if worker.get("status") == "terminated" else now
    return max(0, int(((ended or now) - started).total_seconds()))


def _decorate(worker, now):
    view = dict(worker)
    view["uptimeSeconds"] = _uptime_seconds(worker, now)
    return view


# --- EC2 lookups -------------------------------------------------------------


def _security_group_id():
    groups = EC2.describe_security_groups(
        Filters=[{"Name": "group-name", "Values": [SECURITY_GROUP_NAME]}]
    ).get("SecurityGroups", [])
    if not groups:
        # This Lambda deliberately cannot create it: prereq infrastructure belongs
        # to launch.sh, which builds the group with no ingress rules.
        raise ApiError(503, "security group {} is missing; run launch.sh once to create it".format(SECURITY_GROUP_NAME))
    return groups[0]["GroupId"]


def _ami_id():
    return SSM.get_parameter(Name=AMI_PARAMETER)["Parameter"]["Value"]


def _instance_states(instance_ids):
    """Maps instance id to state name. Filtered rather than looked up by id: an id
    EC2 has forgotten is then simply absent instead of failing the whole batch."""
    states = {}
    ids = [i for i in instance_ids if i]
    for index in range(0, len(ids), 100):
        pages = EC2.get_paginator("describe_instances").paginate(
            Filters=[{"Name": "instance-id", "Values": ids[index:index + 100]}]
        )
        for page in pages:
            for reservation in page.get("Reservations", []):
                for instance in reservation.get("Instances", []):
                    states[instance["InstanceId"]] = instance["State"]["Name"]
    return states


def _tag(instance, key):
    for tag in instance.get("Tags", []):
        if tag.get("Key") == key:
            return tag.get("Value") or ""
    return ""


# --- config auto-provisioning ------------------------------------------------


def _fill_placeholders(node, values):
    """Replaces {{TOKEN}} placeholders inside string values, recursively. The
    substitution happens on the parsed document — never on raw JSON text — so a
    substituted value can never corrupt the re-serialized config."""
    if isinstance(node, dict):
        return {key: _fill_placeholders(value, values) for key, value in node.items()}
    if isinstance(node, list):
        return [_fill_placeholders(value, values) for value in node]
    if isinstance(node, str):
        for token, replacement in values.items():
            node = node.replace(token, replacement)
    return node


def _provision_config(agent, config_key):
    """Instantiates the template as this agent's daemon config, so any agent the
    app names just works instead of refusing agents nobody hand-provisioned.
    Never overwrites: the caller only lands here on a head-check miss, and the
    PUT itself is conditional, so an existing config — hand-provisioned or from
    a concurrent launch — can never be clobbered."""
    slug = _key_slug(agent)
    try:
        raw = S3.get_object(Bucket=BUCKET, Key=TEMPLATE_KEY)["Body"].read()
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code in ("404", "NoSuchKey", "NotFound"):
            # Without a config the instance would boot, fail the fetch, and bill
            # for nothing; refuse before spending the launch — and say why in
            # words the app can surface (the old refusal read as "forbidden").
            raise ApiError(400, (
                "agent {} has no cloud harness config and no template exists to auto-provision one; "
                "upload s3://{}/{} with scripts/cloud-agent/make-config-template.sh, "
                "or hand-provision s3://{}/{}"
            ).format(agent, BUCKET, TEMPLATE_KEY, BUCKET, config_key))
        raise
    try:
        template = json.loads(raw)
    except ValueError:
        template = None
    if not isinstance(template, dict):
        raise ApiError(500, "config template s3://{}/{} is not a JSON object; regenerate it with make-config-template.sh".format(BUCKET, TEMPLATE_KEY))

    def sign(method, key):
        return S3.generate_presigned_url(
            method, Params={"Bucket": BUCKET, "Key": key}, ExpiresIn=TEMPLATE_URL_TTL_SECONDS
        )

    config = _fill_placeholders(template, {
        "{{AGENT}}": agent,
        "{{AGENT_SLUG}}": slug,
        # A fresh identity per agent: the daemon requires agentID to parse as a
        # UUID (uppercase matches the hand-provisioned convention), and
        # deviceToken8 is the 8-char device stamp in its status uplink.
        "{{AGENT_ID}}": str(uuid.uuid4()).upper(),
        "{{DEVICE_TOKEN8}}": uuid.uuid4().hex[:8],
        "{{DIRECTIVE_GET_URL}}": sign("get_object", SUPERVISION_DIRECTIVE_KEY),
        "{{STATUS_PUT_URL}}": sign("put_object", STATUS_KEY.format(agent=slug)),
        "{{INBOX_GET_URL}}": sign("get_object", INBOX_KEY.format(agent=slug)),
        "{{TRANSCRIPT_PUT_URL}}": sign("put_object", TRANSCRIPT_KEY.format(agent=slug)),
    })

    try:
        S3.put_object(
            Bucket=BUCKET,
            Key=config_key,
            Body=json.dumps(config, indent=2).encode("utf-8"),
            ContentType="application/json",
            # Bucket-default SSE applies; the marker lets an operator tell an
            # instantiated config from a hand-provisioned one.
            Metadata={"fin-autoprovisioned": "1"},
            IfNoneMatch="*",
        )
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code not in ("PreconditionFailed", "ConditionalRequestConflict"):
            raise
        # A concurrent launch won the conditional PUT; its config is as good as
        # ours, and the boot fetch below reads whatever is there.
        LOG.info("config for %s was provisioned concurrently", agent)
        return
    LOG.info("auto-provisioned config for %s", agent)


# --- routes ------------------------------------------------------------------


def create_worker(event):
    body = _body(event)

    agent = str(body.get("agent") or "").strip()
    if not AGENT_NAME.match(agent):
        raise ApiError(400, "agent must match [A-Za-z0-9][A-Za-z0-9._-]{0,62}")
    if _key_slug(agent) == SECRET_SCOPE_SHARED:
        # Reserved as the everyone-readable secret scope; an agent by this name
        # would collide with fin/service-creds/shared/*.
        raise ApiError(400, "agent name '{}' is reserved for the shared secret scope".format(SECRET_SCOPE_SHARED))

    instance_type = str(body.get("instanceType") or DEFAULT_INSTANCE_TYPE).strip()
    if instance_type not in PRICE_USD_PER_HOUR:
        raise ApiError(400, "instanceType must be one of: {}".format(", ".join(sorted(PRICE_USD_PER_HOUR))))

    browser = body.get("browser")
    if browser not in (None, True, False):
        raise ApiError(400, "browser must be a boolean")
    browser = bool(browser)
    if browser and PRICE_USD_PER_HOUR[instance_type] < PRICE_USD_PER_HOUR[BROWSER_MIN_INSTANCE_TYPE]:
        raise ApiError(400, "browser workers need {} or larger; chromium on {} dies on memory and bills for nothing".format(
            BROWSER_MIN_INSTANCE_TYPE, instance_type))

    supplied_idle = body.get("idleMinutes")
    try:
        idle_minutes = int(DEFAULT_IDLE_MINUTES if supplied_idle is None else supplied_idle)
    except (TypeError, ValueError):
        raise ApiError(400, "idleMinutes must be an integer")
    if not 1 <= idle_minutes <= MAX_IDLE_MINUTES:
        raise ApiError(400, "idleMinutes must be between 1 and {}".format(MAX_IDLE_MINUTES))

    now = _now()
    existing = [w for w in _live_workers() if w.get("agent") == agent]
    if existing:
        # A record can outlive its instance (terminate.sh, console, spot of bad
        # luck). Reconcile before refusing, or one dead row blocks the agent.
        states = _instance_states([w["instanceId"] for w in existing if w.get("instanceId")])
        alive = []
        for worker in existing:
            state = states.get(worker.get("instanceId"))
            if state in ("pending", "running", "stopping", "stopped"):
                alive.append(worker)
            else:
                _terminate(worker, "instance-gone")
        if alive:
            raise ApiError(409, "agent {} already has a live worker ({})".format(agent, alive[0]["workerId"]))

    config_key = CONFIG_KEY.format(agent=_key_slug(agent))
    try:
        S3.head_object(Bucket=BUCKET, Key=config_key)
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code not in ("404", "NoSuchKey", "NotFound"):
            raise
        # No hand-provisioned config: instantiate the template so the launch
        # proceeds (400s only when the template is missing too).
        _provision_config(agent, config_key)

    user_data = USER_DATA.format(
        binary_url=S3.generate_presigned_url(
            "get_object",
            Params={"Bucket": BUCKET, "Key": BINARY_KEY},
            ExpiresIn=PRESIGN_TTL_SECONDS,
        ),
        config_url=S3.generate_presigned_url(
            "get_object",
            Params={"Bucket": BUCKET, "Key": config_key},
            ExpiresIn=PRESIGN_TTL_SECONDS,
        ),
    )
    if browser:
        user_data += BROWSER_USER_DATA

    # A fresh worker starts with an empty applied-id ledger (it lives on the
    # instance and dies with it), so any message still in the inbox document
    # would REPLAY on boot. The launch is the conversation boundary: empty the
    # inbox first — the transcript object is what persists history.
    S3.put_object(
        Bucket=BUCKET,
        Key=INBOX_KEY.format(agent=_key_slug(agent)),
        Body=b'{"version":1,"directives":[]}',
        ContentType="application/json",
    )

    tags = [
        {"Key": "Name", "Value": "fin-agent-{}".format(agent)},
        {"Key": "fin-agent", "Value": agent},
        {"Key": "fin-managed", "Value": "control-plane"},
        {"Key": "fin-idle-minutes", "Value": str(idle_minutes)},
    ]
    if browser:
        tags.append({"Key": "fin-browser", "Value": "1"})

    instance = EC2.run_instances(
        ImageId=_ami_id(),
        InstanceType=instance_type,
        MinCount=1,
        MaxCount=1,
        SecurityGroupIds=[_security_group_id()],
        IamInstanceProfile={"Name": INSTANCE_PROFILE_NAME},
        UserData=user_data,
        MetadataOptions={"HttpTokens": "required"},
        TagSpecifications=[{"ResourceType": "instance", "Tags": tags}],
    )["Instances"][0]

    worker_id = str(uuid.uuid4())
    launched_at = _iso(instance.get("LaunchTime") or now)
    _record(worker_id, agent, instance["InstanceId"], instance_type, launched_at, idle_minutes, "control-plane", browser)
    LOG.info("launched %s for agent %s (%s%s)", instance["InstanceId"], agent, instance_type, ", browser" if browser else "")

    return _response(201, {
        "workerId": worker_id,
        "instanceId": instance["InstanceId"],
        "agent": agent,
        "instanceType": instance_type,
        "launchedAt": launched_at,
        "browser": browser,
    })


def list_workers(_event):
    now = _now()
    workers = _scan()
    workers.sort(key=lambda w: str(w.get("launchedAt") or ""), reverse=True)
    return _response(200, {"workers": [_decorate(w, now) for w in workers[:MAX_LIST_ITEMS]]})


def delete_worker(_event, worker_id):
    worker = TABLE.get_item(Key={"workerId": worker_id}).get("Item")
    if not worker:
        raise ApiError(404, "no worker {}".format(worker_id))
    if worker.get("status") == "terminated":
        return _response(200, _decorate(worker, _now()))
    final = _terminate(worker, "api")
    LOG.info("terminated %s (worker %s)", worker.get("instanceId"), worker_id)
    return _response(200, _decorate(final, _now()))


def usage(_event):
    now = _now()
    by_agent, by_type, unpriced = {}, {}, set()
    for worker in _scan():
        hours = _uptime_seconds(worker, now) / 3600.0
        instance_type = str(worker.get("instanceType") or "unknown")
        rate = PRICE_USD_PER_HOUR.get(instance_type)
        if rate is None:
            unpriced.add(instance_type)
            rate = 0.0
        cost = hours * rate
        for bucket, key in ((by_agent, str(worker.get("agent") or "unknown")), (by_type, instance_type)):
            row = bucket.setdefault(key, {"uptimeHours": 0.0, "estimatedCostUSD": 0.0, "workers": 0, "live": 0})
            row["uptimeHours"] += hours
            row["estimatedCostUSD"] += cost
            row["workers"] += 1
            row["live"] += 1 if worker.get("status") == "live" else 0

    def rows(bucket, label):
        out = []
        for key, row in sorted(bucket.items(), key=lambda kv: kv[1]["estimatedCostUSD"], reverse=True):
            out.append(dict(row, **{
                label: key,
                "uptimeHours": round(row["uptimeHours"], 3),
                "estimatedCostUSD": round(row["estimatedCostUSD"], 4),
            }))
        return out

    return _response(200, {
        "generatedAt": _iso(now),
        "byAgent": rows(by_agent, "agent"),
        "byInstanceType": rows(by_type, "instanceType"),
        "totalUptimeHours": round(sum(r["uptimeHours"] for r in by_agent.values()), 3),
        "totalEstimatedCostUSD": round(sum(r["estimatedCostUSD"] for r in by_agent.values()), 4),
        "unpricedInstanceTypes": sorted(unpriced),
        "priceNote": "estimated us-west-2 on-demand rates for subscription calibration, not billing truth",
    })


# --- presigned-URL vending ---------------------------------------------------

# Kinds that mint an agent-scoped key (an agent is required), and the app-wide
# supervision kinds that ignore the agent entirely.
AGENT_KINDS = ("transcript", "inbox", "status")
SUPERVISION_KINDS = ("supervisionDirective", "supervisionStatus")
PRESIGN_KINDS = AGENT_KINDS + SUPERVISION_KINDS


def _presign(method, key):
    """One short-lived presigned URL. These are signed with the Lambda's temporary
    credentials, so they die with those even before ExpiresIn — the app re-requests
    on demand rather than leaning on the stated TTL."""
    return S3.generate_presigned_url(
        method,
        Params={"Bucket": BUCKET, "Key": key},
        ExpiresIn=PRESIGN_TTL_SECONDS,
    )


def presign(event):
    body = _body(event)

    agent = str(body.get("agent") or "").strip()

    requested = body.get("kinds")
    if requested is None:
        # Omitted: every kind the request can satisfy — supervision always, the
        # agent-scoped kinds only when an agent is supplied.
        kinds = (list(AGENT_KINDS) if agent else []) + list(SUPERVISION_KINDS)
    else:
        if not isinstance(requested, list) or not all(isinstance(k, str) for k in requested):
            raise ApiError(400, "kinds must be an array of strings")
        kinds = []
        for kind in requested:
            if kind not in PRESIGN_KINDS:
                raise ApiError(400, "unknown kind {}; valid kinds are {}".format(kind, ", ".join(PRESIGN_KINDS)))
            if kind not in kinds:
                kinds.append(kind)

    # Validate the agent only when an agent-scoped kind is in play; supervision
    # kinds never touch the agent name, so a request for them alone needs none.
    slug = None
    if any(kind in AGENT_KINDS for kind in kinds):
        if not AGENT_NAME.match(agent):
            raise ApiError(400, "agent must match [A-Za-z0-9][A-Za-z0-9._-]{0,62}")
        slug = _key_slug(agent)

    urls = {}
    for kind in kinds:
        if kind == "transcript":
            urls["transcriptGet"] = _presign("get_object", TRANSCRIPT_KEY.format(agent=slug))
        elif kind == "inbox":
            inbox_key = INBOX_KEY.format(agent=slug)
            urls["inboxGet"] = _presign("get_object", inbox_key)
            urls["inboxPut"] = _presign("put_object", inbox_key)
        elif kind == "status":
            urls["statusGet"] = _presign("get_object", STATUS_KEY.format(agent=slug))
        elif kind == "supervisionDirective":
            urls["supervisionDirectiveGet"] = _presign("get_object", SUPERVISION_DIRECTIVE_KEY)
        elif kind == "supervisionStatus":
            urls["supervisionStatusPut"] = _presign("put_object", SUPERVISION_STATUS_KEY)

    now = _now()
    return _response(200, {
        "generatedAt": _iso(now),
        "expiresAt": _iso(now + timedelta(seconds=PRESIGN_TTL_SECONDS)),
        "ttlSeconds": PRESIGN_TTL_SECONDS,
        "urls": urls,
    })


# --- model-factory ingest ----------------------------------------------------

# The model-factory data lake is a separate bucket from the agent channel on
# purpose: training telemetry and supervision traffic never share a key space
# or a lifecycle. raw/ objects expire after 180 days (bucket lifecycle rule,
# set by deploy.sh); datasets/, models/, and evals/ persist.
FACTORY_BUCKET = "fin-model-factory-011183829623"

# kind -> key template. The date partition is the SERVER receive date (client
# clocks lie); the client's own createdAt stays inside the document.
FEEDBACK_KEYS = {
    "user_feedback": "raw/feedback/{date}/{uid}.json",
    "trajectory": "raw/trajectories/{date}/{uid}.json",
}

# One stored document. Trajectories bigger than this are chunked app-side.
MAX_FEEDBACK_BYTES = 1024 * 1024


def ingest_feedback(event):
    """POST /feedback — the FROZEN ingest contract the app team builds against.

    Body: {"kind": "user_feedback"|"trajectory", "rating": 1|-1|null,
           "comment": str|null, "payload": object|null, "appVersion": str,
           "platform": str, "createdAt": iso8601}
    400 on a bad kind (or any other field violating the contract), 401
    unauthenticated (enforced before routing), 413 over MAX_FEEDBACK_BYTES.
    Unknown extra fields are dropped, never stored. All app-side data is
    opt-in and pre-redacted before upload; nothing here logs or echoes the
    comment or payload content.
    """
    body = _body(event)

    kind = body.get("kind")
    if kind not in FEEDBACK_KEYS:
        raise ApiError(400, "kind must be one of: {}".format(", ".join(sorted(FEEDBACK_KEYS))))

    rating = body.get("rating")
    if rating is not None and (isinstance(rating, bool) or rating not in (1, -1)):
        raise ApiError(400, "rating must be 1, -1, or null")

    comment = body.get("comment")
    if comment is not None and not isinstance(comment, str):
        raise ApiError(400, "comment must be a string or null")

    payload = body.get("payload")
    if payload is not None and not isinstance(payload, dict):
        raise ApiError(400, "payload must be a JSON object or null")

    app_version = body.get("appVersion")
    if not isinstance(app_version, str) or not app_version.strip():
        raise ApiError(400, "appVersion must be a non-empty string")

    platform = body.get("platform")
    if not isinstance(platform, str) or not platform.strip():
        raise ApiError(400, "platform must be a non-empty string")

    created_at = body.get("createdAt")
    if _parse_iso(created_at) is None:
        raise ApiError(400, "createdAt must be an ISO8601 timestamp")

    now = _now()
    uid = str(uuid.uuid4())
    document = {
        "id": uid,
        "receivedAt": _iso(now),
        "kind": kind,
        "rating": rating,
        "comment": comment,
        "payload": payload,
        "appVersion": app_version.strip(),
        "platform": platform.strip(),
        "createdAt": created_at,
    }
    encoded = json.dumps(document).encode("utf-8")
    if len(encoded) > MAX_FEEDBACK_BYTES:
        raise ApiError(413, "document exceeds {} bytes".format(MAX_FEEDBACK_BYTES))

    key = FEEDBACK_KEYS[kind].format(date=now.strftime("%Y/%m/%d"), uid=uid)
    S3.put_object(Bucket=FACTORY_BUCKET, Key=key, Body=encoded, ContentType="application/json")
    LOG.info("ingested %s %s", kind, uid)
    return _response(201, {"id": uid, "kind": kind, "receivedAt": document["receivedAt"]})


# --- push notifications (APNs) -----------------------------------------------
#
# POST /notify fans one alert out to every device token the app has registered
# via PUT /device-tokens. Transport is APNs' token-based HTTP/2 API: the stdlib
# has no HTTP/2 client and APNs speaks nothing else, so deploy.sh vendors
# httpx+h2 into the zip, plus ecdsa for the ES256 provider JWT — all pure
# python, no compiled wheels, so a zip built on any machine runs unchanged on
# the arm64 python3.12 runtime. Both are imported lazily: a bundle missing them
# fails only /notify, never the worker routes.

APNS_KEY_ID = os.environ.get("APNS_KEY_ID", "")
APNS_TEAM_ID = os.environ.get("APNS_TEAM_ID", "")
APNS_KEY = os.environ.get("APNS_KEY", "")  # the .p8 auth key's PEM content, verbatim
APNS_TOPIC = os.environ.get("APNS_TOPIC", "dev.levischoen.fin")

# A TestFlight build's token lives in the production environment, a devicectl
# debug build's in sandbox, and the registration carries no reliable marker of
# which — so a token is tried against production first and swapped on APNs'
# wrong-environment answer. The discovered environment is stored on the token
# row so later notifies go straight there.
APNS_HOSTS = {
    "production": "https://api.push.apple.com",
    "sandbox": "https://api.sandbox.push.apple.com",
}
APNS_WRONG_ENVIRONMENT = "BadDeviceToken"
# Reasons that mean the token will never work again: drop the row — the app
# re-PUTs a live token on its next launch anyway.
APNS_DEAD_REASONS = ("Unregistered", "ExpiredToken", "DeviceTokenNotForTopic")

# Apple accepts provider JWTs between 20 and 60 minutes old and throttles
# refreshes under 20; 40 sits safely inside both fences. Cached per warm
# container, like boto3's clients above.
APNS_JWT_LIFETIME_SECONDS = 40 * 60
APNS_REQUEST_TIMEOUT = 10

# APNs tokens are 32 bytes (64 hex chars) today, but Apple documents the length
# as opaque; the range keeps hex-ness without hardcoding today's size.
DEVICE_TOKEN = re.compile(r"^[0-9a-f]{16,512}$")
MAX_DEVICE_NAME_LENGTH = 80
MAX_NOTIFY_TITLE_LENGTH = 120
MAX_NOTIFY_BODY_LENGTH = 800

_APNS_JWT_CACHE = {"token": "", "issued_at": 0.0}


def _apns_configured():
    return bool(APNS_KEY_ID and APNS_TEAM_ID and APNS_KEY)


def _b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _apns_bearer(now_epoch=None):
    """The ES256 provider JWT, cached per warm container. `ecdsa` is pure python,
    reads the unencrypted PKCS#8 .p8 directly, and its raw r||s signature form is
    exactly what a JWT wants — no DER wrangling. The JWT is a credential: it must
    never reach a log line or a response body."""
    now_epoch = time.time() if now_epoch is None else now_epoch
    if _APNS_JWT_CACHE["token"] and now_epoch - _APNS_JWT_CACHE["issued_at"] < APNS_JWT_LIFETIME_SECONDS:
        return _APNS_JWT_CACHE["token"]
    import ecdsa  # vendored by deploy.sh
    from ecdsa.util import sigencode_string

    header = _b64url(json.dumps({"alg": "ES256", "kid": APNS_KEY_ID}).encode())
    claims = _b64url(json.dumps({"iss": APNS_TEAM_ID, "iat": int(now_epoch)}).encode())
    key = ecdsa.SigningKey.from_pem(APNS_KEY, hashfunc=hashlib.sha256)
    signature = key.sign_deterministic(
        "{}.{}".format(header, claims).encode(), sigencode=sigencode_string
    )
    token = "{}.{}.{}".format(header, claims, _b64url(signature))
    _APNS_JWT_CACHE.update(token=token, issued_at=now_epoch)
    return token


def _apns_push(client, environment, token, payload, bearer):
    """One POST to one APNs environment. Returns (delivered, reason); the reason
    is APNs' own enum string, or an HTTP status when the body carries none."""
    try:
        response = client.post(
            "{}/3/device/{}".format(APNS_HOSTS[environment], token),
            content=json.dumps(payload),
            headers={
                "authorization": "bearer {}".format(bearer),
                "apns-topic": APNS_TOPIC,
                "apns-push-type": "alert",
                "apns-priority": "10",
            },
        )
    except Exception as exc:  # noqa: BLE001 - httpx transport errors are not ClientError
        return False, _scrub(exc)
    if response.status_code == 200:
        return True, ""
    try:
        reason = str(response.json().get("reason") or "")
    except ValueError:
        reason = ""
    return False, reason or "HTTP {}".format(response.status_code)


def put_device_token(event):
    """PUT /device-tokens — the app re-registers on every launch (APNs rotates
    tokens); the token is the table's hash key, so a re-PUT is a dedupe-by-
    overwrite. update_item rather than put_item on purpose: it preserves the
    `environment` a past /notify discovered, so re-registration doesn't cost the
    next push a wrong-environment round trip."""
    body = _body(event)

    token = str(body.get("token") or "").strip().lower()
    if not DEVICE_TOKEN.match(token):
        raise ApiError(400, "token must be the APNs device token as hex")

    platform = str(body.get("platform") or "").strip()
    if not platform or len(platform) > 40:
        raise ApiError(400, "platform must be a non-empty string of at most 40 characters")

    device_name = body.get("deviceName")
    if device_name is not None and not isinstance(device_name, str):
        raise ApiError(400, "deviceName must be a string")
    device_name = (device_name or "").strip()[:MAX_DEVICE_NAME_LENGTH]

    updated_at = _iso(_now())
    names = {"#platform": "platform", "#updated": "updatedAt", "#name": "deviceName"}
    values = {":platform": platform, ":updated": updated_at}
    expression = "SET #platform = :platform, #updated = :updated"
    if device_name:
        expression += ", #name = :name"
        values[":name"] = device_name
    else:
        expression += " REMOVE #name"
    DEVICE_TOKENS_TABLE.update_item(
        Key={"token": token},
        UpdateExpression=expression,
        ExpressionAttributeNames=names,
        ExpressionAttributeValues=values,
    )
    # The suffix identifies a device across log lines; a token alone moves no
    # pushes without the auth key, but the whole thing still stays out of logs.
    LOG.info("registered device token …%s (%s)", token[-8:], platform)
    return _response(200, {
        "platform": platform,
        "deviceName": device_name or None,
        "updatedAt": updated_at,
    })


def notify(event):
    """POST /notify — {"title", "body", "agent"?}: one APNs alert to every
    registered device. The response reports counts and APNs reason strings only —
    never a token, never the auth key, never the JWT."""
    if not _apns_configured():
        raise ApiError(503, "APNs key is not configured; redeploy with FIN_APNS_KEY_PATH set (see control-plane/README.md)")
    body = _body(event)

    title = str(body.get("title") or "").strip()
    if not title:
        raise ApiError(400, "title must be a non-empty string")
    text = str(body.get("body") or "").strip()
    if not text:
        raise ApiError(400, "body must be a non-empty string")
    # A push is a summary; overlong input is truncated, not refused — the sender
    # is an unattended daemon with nobody there to shorten and retry.
    title = title[:MAX_NOTIFY_TITLE_LENGTH]
    text = text[:MAX_NOTIFY_BODY_LENGTH]

    agent = str(body.get("agent") or "").strip()
    if agent and not AGENT_NAME.match(agent):
        raise ApiError(400, "agent must match [A-Za-z0-9][A-Za-z0-9._-]{0,62}")

    rows = _scan(table=DEVICE_TOKENS_TABLE)
    if not rows:
        return _response(200, {
            "delivered": 0, "failed": 0, "removed": 0,
            "note": "no device tokens registered; launch the app once with the control plane configured",
        })

    try:
        import httpx  # vendored by deploy.sh
    except ImportError:
        raise ApiError(500, "push dependencies are missing from the bundle; rerun deploy.sh")
    try:
        bearer = _apns_bearer()
    except ImportError:
        raise ApiError(500, "push dependencies are missing from the bundle; rerun deploy.sh")
    except Exception:  # noqa: BLE001 - a malformed key must not leak through the error
        LOG.exception("APNs provider JWT signing failed")
        raise ApiError(500, "APNs provider token signing failed; check the deployed APNS_* environment")

    payload = {"aps": {"alert": {"title": title, "body": text}, "sound": "default"}}
    if agent:
        # Custom key for the app's future tap routing; harmless to older builds.
        payload["finAgent"] = agent

    delivered, removed, failures = 0, 0, []
    with httpx.Client(http2=True, timeout=APNS_REQUEST_TIMEOUT) as client:
        for row in rows:
            token = str(row.get("token") or "")
            if not token:
                continue
            first = "sandbox" if row.get("environment") == "sandbox" else "production"
            second = "production" if first == "sandbox" else "sandbox"
            environment = first
            ok, reason = _apns_push(client, first, token, payload, bearer)
            if not ok and reason == APNS_WRONG_ENVIRONMENT:
                environment = second
                ok, reason = _apns_push(client, second, token, payload, bearer)
            if ok:
                delivered += 1
                if environment != row.get("environment"):
                    DEVICE_TOKENS_TABLE.update_item(
                        Key={"token": token},
                        UpdateExpression="SET #env = :env",
                        ExpressionAttributeNames={"#env": "environment"},
                        ExpressionAttributeValues={":env": environment},
                    )
            elif reason in APNS_DEAD_REASONS or reason == APNS_WRONG_ENVIRONMENT:
                # Dead in both environments, or gone for good: the row would only
                # produce failures from here on.
                DEVICE_TOKENS_TABLE.delete_item(Key={"token": token})
                removed += 1
            else:
                failures.append(reason)

    LOG.info("notify: delivered %d, failed %d, removed %d", delivered, len(failures), removed)
    # 502 when tokens exist but nothing got through, so an unattended caller's
    # audit trail records the outage instead of a hollow success.
    return _response(200 if delivered else 502, {
        "delivered": delivered,
        "failed": len(failures),
        "removed": removed,
        "reasons": sorted(set(failures)),
    })


# --- service credentials (write-only) ----------------------------------------
#
# Doctrine (mirrors the bearer-token rule in the module docstring): credential
# field VALUES never reach a log line, an ApiError message, or a response body.
# Field NAMES may appear in validation errors; values never may.


def _secret_scope(raw):
    """Normalizes an agentScope to its key slug; absent means the shared scope."""
    scope = str(raw or SECRET_SCOPE_SHARED).strip()
    if _key_slug(scope) == SECRET_SCOPE_SHARED:
        return SECRET_SCOPE_SHARED
    if not AGENT_NAME.match(scope):
        raise ApiError(400, "agentScope must be '{}' or match [A-Za-z0-9][A-Za-z0-9._-]{{0,62}}".format(SECRET_SCOPE_SHARED))
    return _key_slug(scope)


def _require_service(service):
    if not SERVICE_NAME.match(service):
        raise ApiError(400, "service must match [a-z0-9][a-z0-9-]{0,39}")


def _secret_name(scope, service):
    return "{}/{}/{}".format(SECRET_PREFIX, scope, service)


def put_secret(event, service):
    _require_service(service)
    body = _body(event)
    scope = _secret_scope(body.get("agentScope"))

    kind = str(body.get("kind") or "password").strip()
    if kind not in SECRET_KINDS:
        raise ApiError(400, "kind must be one of: {}".format(", ".join(SECRET_KINDS)))

    # The SecretString is a flat JSON object of string fields — the shape the
    # runner's placeholder resolution addresses. Written once, then discarded;
    # nothing below this block may carry a field value anywhere else.
    fields = {}
    for field in ("value", "username"):
        raw = body.get(field)
        if raw is None:
            continue
        if not isinstance(raw, str) or not raw.strip():
            raise ApiError(400, "{} must be a non-empty string".format(field))
        if len(raw.encode("utf-8")) > MAX_SECRET_FIELD_BYTES:
            raise ApiError(400, "{} exceeds {} bytes".format(field, MAX_SECRET_FIELD_BYTES))
        fields[field] = raw
    if "value" not in fields:
        raise ApiError(400, "value is required")

    note = body.get("note")
    if note is not None:
        if not isinstance(note, str):
            raise ApiError(400, "note must be a string")
        if len(note) > 200:
            raise ApiError(400, "note must be 200 characters or fewer")
        note = note.strip()

    secret_string = json.dumps(fields)
    if len(secret_string.encode("utf-8")) > MAX_SECRET_BYTES:
        raise ApiError(400, "secret exceeds {} bytes".format(MAX_SECRET_BYTES))

    name = _secret_name(scope, service)
    tags = [
        {"Key": "fin-scope", "Value": scope},
        {"Key": "fin-service", "Value": service},
        {"Key": "fin-kind", "Value": kind},
    ]

    created = False
    try:
        kwargs = {"Name": name, "SecretString": secret_string, "Tags": tags}
        if note:
            # The Description is METADATA — visible to anything that can list
            # secrets, not encrypted like the value. Docs warn accordingly.
            kwargs["Description"] = note
        SECRETS.create_secret(**kwargs)
        created = True
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code == "InvalidRequestException":
            # Scheduled for deletion (a prior DELETE's recovery window): bring
            # it back, then overwrite below.
            SECRETS.restore_secret(SecretId=name)
        elif code != "ResourceExistsException":
            raise
    if not created:
        SECRETS.put_secret_value(SecretId=name, SecretString=secret_string)
        SECRETS.tag_resource(SecretId=name, Tags=tags)
        if note is not None:
            SECRETS.update_secret(SecretId=name, Description=note)

    LOG.info("stored service credential %s/%s (%s)", scope, service, kind)
    return _response(201 if created else 200, {
        "service": service,
        "agentScope": scope,
        "kind": kind,
        "lastUpdated": _iso(_now()),
    })


def list_secrets(event):
    """Metadata only — names, tags, and timestamps; never a value (the role
    could not fetch one even if this code tried)."""
    params = event.get("queryStringParameters") or {}
    prefix = SECRET_PREFIX + "/"
    requested_scope = str(params.get("agentScope") or "").strip()
    if requested_scope:
        prefix += _secret_scope(requested_scope) + "/"

    entries, token = [], None
    while len(entries) < MAX_LIST_ITEMS:
        kwargs = {
            "Filters": [{"Key": "name", "Values": [prefix]}],
            "MaxResults": min(100, MAX_LIST_ITEMS - len(entries)),
            "IncludePlannedDeletion": True,
        }
        if token:
            kwargs["NextToken"] = token
        page = SECRETS.list_secrets(**kwargs)
        entries.extend(page.get("SecretList", []))
        token = page.get("NextToken")
        if not token:
            break

    secrets = []
    for entry in entries[:MAX_LIST_ITEMS]:
        tags = {t.get("Key"): t.get("Value") for t in entry.get("Tags") or []}
        name_parts = str(entry.get("Name") or "").split("/")
        row = {
            "service": tags.get("fin-service") or (name_parts[3] if len(name_parts) > 3 else ""),
            "agentScope": tags.get("fin-scope") or (name_parts[2] if len(name_parts) > 2 else ""),
            "kind": tags.get("fin-kind") or "password",
            "label": entry.get("Description") or "",
            "lastUpdated": _iso(entry["LastChangedDate"]) if entry.get("LastChangedDate") else None,
            # Day granularity is all Secrets Manager records — this is the
            # app's "the worker actually read this" signal.
            "lastAccessed": entry["LastAccessedDate"].strftime("%Y-%m-%d") if entry.get("LastAccessedDate") else None,
        }
        if entry.get("DeletedDate"):
            row["deletionScheduled"] = _iso(entry["DeletedDate"])
        secrets.append(row)
    secrets.sort(key=lambda r: (r["agentScope"], r["service"]))
    return _response(200, {"generatedAt": _iso(_now()), "secrets": secrets})


def delete_secret(event, service):
    _require_service(service)
    params = event.get("queryStringParameters") or {}
    scope = _secret_scope(params.get("agentScope"))
    name = _secret_name(scope, service)
    try:
        deletion = SECRETS.delete_secret(
            SecretId=name, RecoveryWindowInDays=SECRET_RECOVERY_DAYS
        ).get("DeletionDate")
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code == "ResourceNotFoundException":
            raise ApiError(404, "no secret for service {} in scope {}".format(service, scope))
        if code != "InvalidRequestException":
            raise
        # Already scheduled: idempotent — answer 200 with the same clock.
        marked = SECRETS.describe_secret(SecretId=name).get("DeletedDate")
        deletion = (marked + timedelta(days=SECRET_RECOVERY_DAYS)) if marked else None
    LOG.info("scheduled deletion of service credential %s/%s", scope, service)
    return _response(200, {
        "service": service,
        "agentScope": scope,
        "deletionDate": _iso(deletion) if deletion else None,
    })


# --- sweep -------------------------------------------------------------------


def _read_status(agent):
    """The agent's status document, or None when it is missing or unparseable."""
    try:
        raw = S3.get_object(Bucket=BUCKET, Key=STATUS_KEY.format(agent=_key_slug(agent)))["Body"].read()
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code in ("404", "NoSuchKey", "NoSuchBucket", "AccessDenied"):
            return None
        raise
    try:
        parsed = json.loads(raw)
    except ValueError:
        LOG.warning("status object for %s is not JSON", agent)
        return None
    return parsed if isinstance(parsed, dict) else None


def _sweep_verdict(worker, now):
    """Why this worker should die, or None to leave it running."""
    idle = timedelta(minutes=int(worker.get("idleMinutes") or DEFAULT_IDLE_MINUTES))
    launched = _parse_iso(worker.get("launchedAt")) or now

    status = _read_status(str(worker.get("agent") or ""))
    if status is None:
        if now - launched < timedelta(minutes=BOOT_GRACE_MINUTES):
            return None
        return "no status object {} minutes after launch".format(BOOT_GRACE_MINUTES)

    updated = _parse_iso(status.get("updated_at"))
    if updated is None or now - updated > idle:
        # The harness PUTs status after every poll, so a stale stamp means the
        # daemon is dead, wedged, or cut off from the bucket.
        return "status stale since {}".format(status.get("updated_at") or "never")

    if status.get("state") in IDLE_STATES:
        # updated_at cannot carry idleness on its own — a healthy idle daemon
        # refreshes it every poll — so the clock runs from the last real turn,
        # or from launch for a worker that has never taken one.
        since = _parse_iso(status.get("last_turn_at")) or launched
        if now - since > idle:
            return "{} since {}".format(status.get("state"), _iso(since))

    return None


def _adopt(now, known_instance_ids):
    """Gives hand-launched instances a record so the sweep can reach them too."""
    adopted = []
    pages = EC2.get_paginator("describe_instances").paginate(
        Filters=[
            {"Name": "tag-key", "Values": ["fin-agent"]},
            {"Name": "instance-state-name", "Values": ["pending", "running"]},
        ]
    )
    for page in pages:
        for reservation in page.get("Reservations", []):
            for instance in reservation.get("Instances", []):
                instance_id = instance["InstanceId"]
                if instance_id in known_instance_ids:
                    continue
                idle_tag = _tag(instance, "fin-idle-minutes")
                worker = _record(
                    str(uuid.uuid4()),
                    _tag(instance, "fin-agent") or "unknown",
                    instance_id,
                    instance.get("InstanceType", "unknown"),
                    _iso(instance.get("LaunchTime") or now),
                    int(idle_tag) if idle_tag.isdigit() else DEFAULT_IDLE_MINUTES,
                    "adopted",
                )
                adopted.append(worker)
                LOG.info("adopted %s for agent %s", instance_id, worker["agent"])
    return adopted


def sweep(_event=None):
    now = _now()
    live = _live_workers()
    adopted = _adopt(now, {w.get("instanceId") for w in live})
    live.extend(adopted)

    states = _instance_states([w["instanceId"] for w in live if w.get("instanceId")])
    terminated, reconciled = [], []
    for worker in live:
        if states.get(worker.get("instanceId")) not in ("pending", "running", "stopping", "stopped"):
            # Gone from EC2 already; stamping it keeps /usage from billing a
            # dead worker forever.
            _terminate(worker, "instance-gone")
            reconciled.append(worker["workerId"])
            continue
        verdict = _sweep_verdict(worker, now)
        if verdict:
            _terminate(worker, "idle-sweep")
            terminated.append({
                "workerId": worker["workerId"],
                "agent": worker.get("agent"),
                "instanceId": worker.get("instanceId"),
                "detail": verdict,
            })
            LOG.info("swept %s (agent %s): %s", worker.get("instanceId"), worker.get("agent"), verdict)

    return {
        "generatedAt": _iso(now),
        "checked": len(live),
        "terminated": terminated,
        "reconciled": reconciled,
        "adopted": [{"workerId": w["workerId"], "agent": w["agent"], "instanceId": w["instanceId"]} for w in adopted],
    }


# --- entry point -------------------------------------------------------------


def _route(event):
    http = (event.get("requestContext") or {}).get("http") or {}
    method = str(http.get("method") or "").upper()
    path = str(event.get("rawPath") or http.get("path") or "/").rstrip("/") or "/"
    parts = [p for p in path.split("/") if p]

    if method == "POST" and parts == ["workers"]:
        return create_worker(event)
    if method == "GET" and parts == ["workers"]:
        return list_workers(event)
    if method == "DELETE" and len(parts) == 2 and parts[0] == "workers":
        return delete_worker(event, parts[1])
    if method == "GET" and parts == ["usage"]:
        return usage(event)
    if method == "POST" and parts == ["sweep"]:
        return _response(200, sweep(event))
    if method == "POST" and parts == ["presign"]:
        return presign(event)
    if method == "POST" and parts == ["feedback"]:
        return ingest_feedback(event)
    if method == "PUT" and parts == ["device-tokens"]:
        return put_device_token(event)
    if method == "POST" and parts == ["notify"]:
        return notify(event)
    if method == "GET" and parts == ["secrets"]:
        return list_secrets(event)
    if method == "PUT" and len(parts) == 2 and parts[0] == "secrets":
        return put_secret(event, parts[1])
    if method == "DELETE" and len(parts) == 2 and parts[0] == "secrets":
        return delete_secret(event, parts[1])
    raise ApiError(404, "no route for {} {}".format(method or "?", path))


def lambda_handler(event, _context=None):
    event = event if isinstance(event, dict) else {}

    # EventBridge invokes the function directly, so there is no HTTP envelope to
    # authorize; the schedule's invoke permission is the authorization.
    if event.get("source") == "sweep-schedule":
        return sweep(event)

    try:
        _authorize(event)
        return _route(event)
    except ApiError as exc:
        return _response(exc.status, {"error": exc.message})
    except ClientError as exc:
        LOG.exception("aws call failed")
        message = exc.response.get("Error", {}).get("Message", "AWS call failed")
        return _response(502, {"error": _scrub(message)})
    except Exception as exc:  # noqa: BLE001 - the API must not leak a stack trace
        LOG.exception("unhandled error")
        return _response(500, {"error": _scrub(exc)})
