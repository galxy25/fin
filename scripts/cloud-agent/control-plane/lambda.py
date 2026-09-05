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
"""

import base64
import hmac
import json
import logging
import os
import re
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

# Reads are capped rather than paginated to exhaustion: one item per worker ever
# launched keeps this table in the hundreds, which is also why a Scan beats
# maintaining a GSI here.
MAX_SCAN_ITEMS = 5000
MAX_LIST_ITEMS = 100

_SESSION = boto3.session.Session(region_name=REGION)
EC2 = _SESSION.client("ec2")
SSM = _SESSION.client("ssm")
S3 = _SESSION.client("s3", config=Config(signature_version="s3v4"))
TABLE = _SESSION.resource("dynamodb").Table(TABLE_NAME)

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


def _scan(**kwargs):
    items, start = [], None
    while len(items) < MAX_SCAN_ITEMS:
        if start:
            kwargs["ExclusiveStartKey"] = start
        page = TABLE.scan(**kwargs)
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


def _record(worker_id, agent, instance_id, instance_type, launched_at, idle_minutes, managed):
    item = {
        "workerId": worker_id,
        "agent": agent,
        "instanceId": instance_id,
        "instanceType": instance_type,
        "launchedAt": launched_at,
        "idleMinutes": int(idle_minutes),
        "status": "live",
        "managed": managed,
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


# --- routes ------------------------------------------------------------------


def create_worker(event):
    body = _body(event)

    agent = str(body.get("agent") or "").strip()
    if not AGENT_NAME.match(agent):
        raise ApiError(400, "agent must match [A-Za-z0-9][A-Za-z0-9._-]{0,62}")

    instance_type = str(body.get("instanceType") or DEFAULT_INSTANCE_TYPE).strip()
    if instance_type not in PRICE_USD_PER_HOUR:
        raise ApiError(400, "instanceType must be one of: {}".format(", ".join(sorted(PRICE_USD_PER_HOUR))))

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
        if code in ("404", "NoSuchKey", "NotFound"):
            # Without a config the instance boots, fails the fetch, and bills for
            # nothing; refuse before spending the launch.
            raise ApiError(400, "no daemon config at s3://{}/{}".format(BUCKET, config_key))
        raise

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

    instance = EC2.run_instances(
        ImageId=_ami_id(),
        InstanceType=instance_type,
        MinCount=1,
        MaxCount=1,
        SecurityGroupIds=[_security_group_id()],
        IamInstanceProfile={"Name": INSTANCE_PROFILE_NAME},
        UserData=user_data,
        MetadataOptions={"HttpTokens": "required"},
        TagSpecifications=[
            {
                "ResourceType": "instance",
                "Tags": [
                    {"Key": "Name", "Value": "fin-agent-{}".format(agent)},
                    {"Key": "fin-agent", "Value": agent},
                    {"Key": "fin-managed", "Value": "control-plane"},
                    {"Key": "fin-idle-minutes", "Value": str(idle_minutes)},
                ],
            }
        ],
    )["Instances"][0]

    worker_id = str(uuid.uuid4())
    launched_at = _iso(instance.get("LaunchTime") or now)
    _record(worker_id, agent, instance["InstanceId"], instance_type, launched_at, idle_minutes, "control-plane")
    LOG.info("launched %s for agent %s (%s)", instance["InstanceId"], agent, instance_type)

    return _response(201, {
        "workerId": worker_id,
        "instanceId": instance["InstanceId"],
        "agent": agent,
        "instanceType": instance_type,
        "launchedAt": launched_at,
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
