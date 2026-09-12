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
import binascii
import hashlib
import hmac
import json
import logging
import os
import re
import secrets
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
# Every per-user object lives under users/{user}/... — {user} is always our
# own userId (fin-users' uuid4), never Apple's `sub` or anything client-
# supplied; every route resolves it from event["_userId"] (set by
# _authorize) and threads it in here, never trusts a request body/path value
# for it. Two keys are deliberately account-wide, not per-user data, and stay
# unprefixed: BINARY_KEY (the harness binary itself) and TEMPLATE_KEY (the
# operator's config template, instantiated per-agent on first launch).
BINARY_KEY = "fin/agentd/fin-agentd"
CONFIG_KEY = "users/{user}/fin/agentd/{agent}.json"
STATUS_KEY = "users/{user}/fin/status-{agent}.json"
INBOX_KEY = "users/{user}/fin/inbox/{agent}.json"
INBOX_LOCK_KEY = "users/{user}/fin/inbox/{agent}.lock"
TRANSCRIPT_KEY = "users/{user}/fin/transcripts/{agent}.jsonl"
# Hourly chunks, distinct from TRANSCRIPT_KEY above — see "cloud transcript
# (hourly S3 chunks)" below for why this exists alongside the rolling object.
TRANSCRIPT_CHUNK_KEY = "users/{user}/fin/transcripts/{agent}/{hour}.jsonl"
MEMORY_KEY = "users/{user}/fin/memory/{agent}.json"


def _artifact_prefix(user_id):
    return "users/{}/fin/artifacts/".format(user_id)


# Auto-provisioning: when POST /workers finds no config for an agent, it
# instantiates this template — the hand-provisioned config shape with every
# per-agent value replaced by a {{PLACEHOLDER}} token. The operator generates it
# from a live config with scripts/cloud-agent/make-config-template.sh (S3 to S3,
# so the shared LLM bearer token inside never lands in git). Account-wide on
# purpose: one template seeds every user's first launch.
TEMPLATE_KEY = "fin/agentd/_template.json"

# Presign lifetime for the supervision/transcript URLs baked into an
# auto-provisioned config: the SigV4 maximum. The stated week is an upper bound,
# not a promise — these are signed with the Lambda role's temporary credentials
# and die with them (hours), unlike the operator-minted URLs in a
# hand-provisioned config. See "Auto-provisioning" in control-plane/README.md.
TEMPLATE_URL_TTL_SECONDS = 7 * 24 * 3600

# The per-user supervision channel: two objects with no agent slug — the
# directive document the app reads and the supervision status the app writes
# back. Used to be account-wide (a single pair of objects for everyone); with
# more than one user that would merge every user's directives into one
# object — silent data corruption, not just a leak — so these are per-user too.
SUPERVISION_DIRECTIVE_KEY = "users/{user}/fin/directives.json"

# Per-device supervision status: one object per (user, device), keyed by the
# app's 8-hex device id — NOT under fin/sites/, which is already load-bearing
# for a different, agent-scoped shape (fin/sites/{agent}/{site8}/status.json,
# see provision-config.sh and _known_last_turn_ats). This root is device-scoped
# and deliberately separate to avoid an ambiguous prefix listing and a
# (however unlikely) name collision between an agent slug and a device id.
DEVICE_STATUS_KEY = "users/{user}/fin/devices/{device}/status.json"
DEVICE_ID_RE = re.compile(r"^[0-9a-f]{8}$")

# The pre-per-device key, still live. Every client build shipped before
# deviceId8 existed asks for kind supervisionStatus WITHOUT one, and those
# builds are out in the world (TestFlight, App Store) for as long as it takes
# users to update — so this is a fallback, not dead code. Rejecting those
# requests instead would break status uplink on every existing install the
# moment this Lambda deploys, which is a worse outage than the account-wide
# key it replaces. Retire it only once no client is still asking.
LEGACY_SUPERVISION_STATUS_KEY = "users/{user}/fin/status.json"


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
# Multi-tenancy identity: fin-users maps Apple's stable per-app-per-user `sub`
# to our own userId (a fresh uuid4 — Apple's identifier never needs to leak
# into S3 keys, EC2 tags, or any other table); fin-sessions maps an opaque
# bearer token to a userId, the same "the natural lookup key is the hash key"
# shape DEVICE_TOKENS_TABLE already uses. See _authorize/_verify_apple_identity_token.
USERS_TABLE_NAME = os.environ.get("FIN_CP_USERS_TABLE", "fin-users")
SESSIONS_TABLE_NAME = os.environ.get("FIN_CP_SESSIONS_TABLE", "fin-sessions")
# Sites (docs/SITES.md): one row per BODY that can act as an agent — an EC2
# worker, the resident daemon on a Mac, a BYO box, or an app install. Its own
# table for the same reason fin-device-tokens is: fin-cloud-workers' rows ARE
# EC2 instances (list_workers scans it whole, /usage prices it, the sweep
# terminates from it), and a resident Mac row in there would be swept to
# "instance-gone" and billed as unpriced. A site is owned by exactly one user:
# `userId` is on every row, and a site token is a second way to BECOME that
# user, never a way to skip being one.
SITES_TABLE_NAME = os.environ.get("FIN_CP_SITES_TABLE", "fin-sites")
# Messages and per-agent election state (docs/SITES.md §3, §6). fin-messages
# is keyed by the client-minted messageId so a retry is a no-op; fin-agents is
# keyed per (user, agent) and holds the primary role's lease.
MESSAGES_TABLE_NAME = os.environ.get("FIN_CP_MESSAGES_TABLE", "fin-messages")
AGENTS_TABLE_NAME = os.environ.get("FIN_CP_AGENTS_TABLE", "fin-agents")
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

# DeviceIdentity.short's shape (fin/Models/DeviceIdentity.swift): lowercase hex,
# 8 characters — the app-side origin-device id a /notify push's tap routing
# echoes back verbatim.
DEVICE_ID8 = re.compile(r"^[0-9a-f]{8}$")

# --- service-credential store (Secrets Manager) ------------------------------
# Secrets live at users/<user>/fin/service-creds/<agentScope>/<service>. The
# scope is the agent's key slug (lowercased display name), or the reserved
# scope "shared", which every one of THAT USER's workers may read — and
# which POST /workers refuses as an agent name so the two can never collide.
# Per-user like everything else here: one user's "shared" scope never reaches
# another's secrets.
SECRET_PREFIX = "users/{user}/fin/service-creds"
SECRET_SCOPE_SHARED = "shared"
SERVICE_NAME = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
SECRET_KINDS = ("app-password", "oauth", "api-key", "password")
# The flat SecretString fields a PUT may carry. value/username are the generic
# credential shape; privateKey/publicKey are what the app's "Fin's Key" screen
# stores under the reserved service fin-agent-ssh-key (shared scope), which the
# worker bootstrap installs at boot. A secret must carry value or privateKey.
SECRET_FIELDS = ("value", "username", "privateKey", "publicKey")
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
USERS_TABLE = _DYNAMODB.Table(USERS_TABLE_NAME)
SESSIONS_TABLE = _DYNAMODB.Table(SESSIONS_TABLE_NAME)
SITES_TABLE = _DYNAMODB.Table(SITES_TABLE_NAME)
MESSAGES_TABLE = _DYNAMODB.Table(MESSAGES_TABLE_NAME)
AGENTS_TABLE = _DYNAMODB.Table(AGENTS_TABLE_NAME)
ENROLL_TOKENS_TABLE = _DYNAMODB.Table(os.environ.get("FIN_CP_ENROLL_TOKENS_TABLE", "fin-enroll-tokens"))

# Byte-for-byte the bootstrap from launch.sh; the two presigned URLs are the only
# substitutions. Any change to launch.sh's user-data belongs here too —
# scripts/cloud-agent/check-userdata-parity.py verifies the contract.
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

# --- Fin's key (optional): the SSH identity the app provisions ---------------
# When the app has stored fin/service-creds/shared/fin-agent-ssh-key ("Provision
# to Cloud Workers" under Fin's Key), install the private key BEFORE the daemon
# starts so a config's server.privateKeyPath can point at
# /home/fin-agent/.ssh/fin_agent_ed25519. A missing secret (or a role without
# the read grant) is a clean no-op: the worker boots exactly as before.
if (umask 077 && aws --region us-west-2 secretsmanager get-secret-value --secret-id fin/service-creds/shared/fin-agent-ssh-key --query SecretString --output text > /run/fin-agent-key.json) 2>/dev/null; then
  python3 - <<'PYKEY' || echo 'FIN AGENT KEY INSTALL FAILED'
import json, os, pwd
fields = json.load(open("/run/fin-agent-key.json"))
key = (fields.get("privateKey") or "").strip()
if key:
    path = "/home/fin-agent/.ssh/fin_agent_ed25519"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.write(fd, key.encode() + chr(10).encode())
    os.close(fd)
    entry = pwd.getpwnam("fin-agent")
    os.chown(path, entry.pw_uid, entry.pw_gid)
    print("installed fin agent key")
else:
    print("fin-agent-ssh-key has no privateKey field; nothing installed")
PYKEY
fi
rm -f /run/fin-agent-key.json

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


# --- multi-tenant identity -----------------------------------------------
#
# Every route used to run for one account under one static shared secret
# (FIN_CP_TOKEN). Now `_authorize` resolves WHO is calling — attaching
# `event["_userId"]` — and every route scopes its S3 keys and DynamoDB rows to
# that id (Phase B). The legacy static token still works during the
# transition (FIN_CP_LEGACY_USER_ID maps it to one real, already-minted
# userId — never a separate "anonymous tenant" concept) so nothing already
# running breaks while sign-in rolls out; removed once every client has a
# real session (see the plan's Phase D).

APPLE_ISSUER = "https://appleid.apple.com"
APPLE_AUDIENCE = os.environ.get("APPLE_BUNDLE_ID", "dev.levischoen.fin")
APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys"
APPLE_JWKS_CACHE_SECONDS = 24 * 3600
APPLE_JWKS_REQUEST_TIMEOUT = 10
# EMSA-PKCS1-v1_5's DigestInfo prefix for SHA-256 (RFC 8017 Appendix A.2.4/
# RFC 3447) — a fixed constant for every SHA-256 PKCS1v1.5 signature, not
# Apple-specific.
_SHA256_DIGESTINFO_PREFIX = bytes.fromhex("3031300d060960864801650304020105000420")
_SESSION_LIFETIME_SECONDS = 365 * 24 * 3600

_apple_jwks_cache = {"keys": None, "fetched_at": 0.0}


def _b64url_decode(segment):
    padding = "=" * (-len(segment) % 4)
    return base64.urlsafe_b64decode(segment + padding)


def _apple_jwks(now_epoch=None, force_refresh=False):
    now_epoch = time.time() if now_epoch is None else now_epoch
    cached = _apple_jwks_cache["keys"]
    if not force_refresh and cached is not None and now_epoch - _apple_jwks_cache["fetched_at"] < APPLE_JWKS_CACHE_SECONDS:
        return cached
    import httpx  # vendored by deploy.sh
    response = httpx.get(APPLE_JWKS_URL, timeout=APPLE_JWKS_REQUEST_TIMEOUT)
    response.raise_for_status()
    keys = response.json().get("keys") or []
    _apple_jwks_cache.update(keys=keys, fetched_at=now_epoch)
    return keys


def _rsa_pkcs1v15_verify(message, signature, n, e):
    """RFC 8017 EMSA-PKCS1-v1_5 verify for RS256: PKCS1v1.5 is modular
    exponentiation (`pow`, stdlib, no library — RSA's public-key operation is
    literally `pow(signature, e, n)`) against a fixed padding+DigestInfo
    layout. `message` is the exact bytes that were signed; `signature`/`n`/`e`
    are big-endian ints. Returns bool, never raises — a verification failure
    is data, not an error, so a malformed signature can't become a 500."""
    key_bytes = (n.bit_length() + 7) // 8
    if not (0 <= signature < n):
        return False
    padded = pow(signature, e, n).to_bytes(key_bytes, "big")
    expected_t = _SHA256_DIGESTINFO_PREFIX + hashlib.sha256(message).digest()
    ps_len = key_bytes - 3 - len(expected_t)
    if ps_len < 8:
        return False
    expected = b"\x00\x01" + b"\xff" * ps_len + b"\x00" + expected_t
    return hmac.compare_digest(padded, expected)


def _verify_apple_identity_token(identity_token, now=None):
    """Verifies a Sign in with Apple identity token and returns its `sub`
    claim (Apple's stable per-app-per-user id). Raises ApiError on any
    failure — malformed token, unknown signing key, bad signature, wrong
    issuer/audience, expiry — never returns a claim from an unverified token."""
    now = _now() if now is None else now
    parts = (identity_token or "").split(".")
    if len(parts) != 3:
        raise ApiError(401, "malformed identity token")
    header_b64, payload_b64, signature_b64 = parts
    try:
        header = json.loads(_b64url_decode(header_b64))
        payload = json.loads(_b64url_decode(payload_b64))
        signature = int.from_bytes(_b64url_decode(signature_b64), "big")
    except (ValueError, TypeError, binascii.Error):
        raise ApiError(401, "malformed identity token")
    if not isinstance(header, dict) or not isinstance(payload, dict):
        raise ApiError(401, "malformed identity token")

    if header.get("alg") != "RS256":
        raise ApiError(401, "unsupported identity token algorithm")
    kid = header.get("kid")
    matching = next((k for k in _apple_jwks() if k.get("kid") == kid), None)
    if matching is None:
        # Apple rotates signing keys; one stale cached fetch shouldn't wedge
        # every sign-in until the next natural refresh.
        matching = next((k for k in _apple_jwks(force_refresh=True) if k.get("kid") == kid), None)
    if matching is None:
        raise ApiError(401, "unknown identity token signing key")

    try:
        n = int.from_bytes(_b64url_decode(matching["n"]), "big")
        e = int.from_bytes(_b64url_decode(matching["e"]), "big")
    except (ValueError, TypeError, KeyError, binascii.Error):
        raise ApiError(401, "malformed identity token signing key")
    message = "{}.{}".format(header_b64, payload_b64).encode("ascii")
    if not _rsa_pkcs1v15_verify(message, signature, n, e):
        raise ApiError(401, "identity token signature is invalid")

    if payload.get("iss") != APPLE_ISSUER:
        raise ApiError(401, "identity token has the wrong issuer")
    if payload.get("aud") != APPLE_AUDIENCE:
        raise ApiError(401, "identity token has the wrong audience")
    exp = payload.get("exp")
    if not isinstance(exp, (int, float)) or now.timestamp() >= exp:
        raise ApiError(401, "identity token has expired")
    sub = payload.get("sub")
    if not isinstance(sub, str) or not sub:
        raise ApiError(401, "identity token has no subject")
    return sub


def _get_or_create_user(apple_sub):
    """fin-users is keyed by appleSub (the only lookup direction sign-in
    needs); userId is a fresh uuid4 so Apple's own identifier never has to
    appear in an S3 key or an EC2 tag."""
    existing = USERS_TABLE.get_item(Key={"appleSub": apple_sub}).get("Item")
    now = _iso(_now())
    if existing:
        USERS_TABLE.update_item(
            Key={"appleSub": apple_sub},
            UpdateExpression="SET lastSeenAt = :now",
            ExpressionAttributeValues={":now": now},
        )
        return existing["userId"]
    user_id = str(uuid.uuid4())
    USERS_TABLE.put_item(Item={
        "appleSub": apple_sub, "userId": user_id, "createdAt": now, "lastSeenAt": now,
    })
    return user_id


def _create_session(user_id):
    token = secrets.token_hex(32)
    now = _now()
    SESSIONS_TABLE.put_item(Item={
        "token": token,
        "userId": user_id,
        "createdAt": _iso(now),
        "lastSeenAt": _iso(now),
        "expiresAt": _iso(now + timedelta(seconds=_SESSION_LIFETIME_SECONDS)),
        # DynamoDB TTL wants epoch seconds; deletion is lazy (up to ~48h late)
        # so _authorize below still checks expiresAt explicitly — this
        # attribute only bounds how long an unused row lingers.
        "ttl": int((now + timedelta(seconds=_SESSION_LIFETIME_SECONDS)).timestamp()),
    })
    return token


def _read_session(token, now=None):
    """None for a missing, malformed, or expired session — the caller (only
    _authorize) turns that into a 401; a lazily-undeleted TTL row past its own
    expiresAt is treated exactly like a missing one."""
    now = _now() if now is None else now
    item = SESSIONS_TABLE.get_item(Key={"token": token}).get("Item")
    if not item:
        return None
    expires_at = _parse_iso(item.get("expiresAt"))
    if expires_at is None or now >= expires_at:
        return None
    return item


def auth_apple(event):
    """POST /auth/apple — {"identityToken"}. The one route that doesn't need
    a prior bearer token; it's how one is obtained. Never logs the identity
    token or the minted session token."""
    body = _body(event)
    identity_token = body.get("identityToken")
    if not isinstance(identity_token, str) or not identity_token:
        raise ApiError(400, "identityToken must be a non-empty string")
    apple_sub = _verify_apple_identity_token(identity_token)
    user_id = _get_or_create_user(apple_sub)
    session_token = _create_session(user_id)
    return _response(200, {"token": session_token})


def _authorize(event):
    presented = _header(event, "authorization").strip()
    scheme, _, token = presented.partition(" ")
    token = token.strip()
    if scheme.lower() != "bearer" or not token:
        raise ApiError(401, "unauthorized")

    # A site token (docs/SITES.md §3.1) presents `X-Fin-Site: <siteId>` alongside
    # the bearer. It is checked FIRST and exclusively: a caller who names a site
    # is asking to act as that body, and silently falling through to operator or
    # session auth when the site check fails would turn a revoked site token into
    # whatever else the same string happens to unlock.
    site_id = _header(event, "x-fin-site").strip().lower()
    if site_id:
        site = _read_site(site_id)
        presented_hash = _site_token_hash(token)
        stored_hash = (site or {}).get("tokenSha256") or ""
        # compare_digest against a dummy of equal shape even when the site is
        # missing or retired, so a wrong id and a wrong token cost the same.
        if not hmac.compare_digest(presented_hash, stored_hash or "0" * 64):
            raise ApiError(401, "unauthorized")
        if not site or site.get("state") == "retired" or not site.get("userId"):
            raise ApiError(401, "unauthorized")
        event["_userId"] = site["userId"]
        event["_siteId"] = site["siteId"]
        return

    legacy_token = os.environ.get("FIN_CP_TOKEN") or ""
    legacy_user_id = os.environ.get("FIN_CP_LEGACY_USER_ID") or ""
    if legacy_token and legacy_user_id and hmac.compare_digest(token.encode(), legacy_token.encode()):
        event["_userId"] = legacy_user_id
        return

    session = _read_session(token)
    if session is None:
        raise ApiError(401, "unauthorized")
    event["_userId"] = session["userId"]
    SESSIONS_TABLE.update_item(
        Key={"token": token},
        UpdateExpression="SET lastSeenAt = :now",
        ExpressionAttributeValues={":now": _iso(_now())},
    )


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


def _live_workers(user_id=None):
    """All live workers, or (whenever the caller has a userId to scope to —
    every route handler except the wake/sweep schedules, which iterate over
    every user themselves) just one user's. `user_id=None` is deliberately
    still available for the schedules; every HTTP route MUST pass one."""
    if user_id is None:
        return _scan(
            FilterExpression="#s = :live",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":live": "live"},
        )
    return _scan(
        FilterExpression="#s = :live AND userId = :user",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":live": "live", ":user": user_id},
    )


def _record(worker_id, user_id, agent, instance_id, instance_type, launched_at, idle_minutes, managed, browser=False, site_id=None):
    item = {
        "workerId": worker_id,
        "userId": user_id,
        "agent": agent,
        "instanceId": instance_id,
        "instanceType": instance_type,
        "launchedAt": launched_at,
        "idleMinutes": int(idle_minutes),
        "status": "live",
        "managed": managed,
        "browser": bool(browser),
    }
    if site_id:
        item["siteId"] = site_id
    TABLE.put_item(Item=item)
    return item


def _overlay_site_onto_config(config_key, site):
    """Read-modify-write the instance's config: add the `site` block and swap the
    control-plane bearer for the site token. `inboxURL` is dropped (Phase 3:
    messages arrive by claim, and the inbox object is retired); everything else
    in the config is left exactly as provisioned."""
    try:
        config = json.loads(S3.get_object(Bucket=BUCKET, Key=config_key)["Body"].read())
    except (ClientError, ValueError):
        raise ApiError(500, "worker config at {} is unreadable".format(config_key))
    if not isinstance(config, dict):
        raise ApiError(500, "worker config at {} is not a JSON object".format(config_key))
    config["site"] = {
        "id": site["siteId"], "kind": "ec2", "displayName": "Cloud computer",
        "token": site["siteToken"], "heartbeatSeconds": site.get("heartbeatSeconds", SITE_HEARTBEAT_SECONDS),
    }
    control_plane = config.get("controlPlane") if isinstance(config.get("controlPlane"), dict) else {}
    control_plane["token"] = site["siteToken"]
    config["controlPlane"] = control_plane
    supervision = config.get("supervision")
    if isinstance(supervision, dict):
        supervision.pop("inboxURL", None)
    S3.put_object(Bucket=BUCKET, Key=config_key, Body=json.dumps(config, indent=2).encode("utf-8"), ContentType="application/json")


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


def _provision_config(user_id, agent, config_key):
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
        "{{DIRECTIVE_GET_URL}}": sign("get_object", SUPERVISION_DIRECTIVE_KEY.format(user=user_id)),
        "{{STATUS_PUT_URL}}": sign("put_object", STATUS_KEY.format(user=user_id, agent=slug)),
        "{{INBOX_GET_URL}}": sign("get_object", INBOX_KEY.format(user=user_id, agent=slug)),
        "{{TRANSCRIPT_PUT_URL}}": sign("put_object", TRANSCRIPT_KEY.format(user=user_id, agent=slug)),
    })
    # fin-agentd 1.4.1 seeds the inbox as history on a first run unless the config
    # says the launcher emptied the inbox first — create_worker does, right before
    # the instance launch — so a message sent while the worker boots still applies.
    # setdefault: a template that already says so (either way) wins.
    supervision = config.get("supervision")
    if isinstance(supervision, dict):
        supervision.setdefault("inboxResetAtLaunch", True)

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


def _launch_worker(user_id, agent, instance_type, idle_minutes, browser, now, clear_inbox=True):
    """The actual EC2 launch, shared by the explicit `POST /workers` route and
    the automatic wake sweep below. Callers own their own pre-checks (agent
    validation, the 409-on-already-live reconciliation) — this just launches
    and records.

    `clear_inbox` defaults True, preserving `create_worker`'s original meaning:
    a manually-started worker begins a fresh conversation boundary, so any
    still-queued inbox messages are discarded (a fresh instance's applied-id
    ledger is empty and would otherwise replay them on boot). The wake sweep
    passes False for the opposite reason — it launches BECAUSE a message is
    sitting unanswered, so wiping it on the way up would defeat the whole
    point of waking at all.
    """
    worker_id = str(uuid.uuid4())
    config_key = CONFIG_KEY.format(user=user_id, agent=_key_slug(agent))
    try:
        S3.head_object(Bucket=BUCKET, Key=config_key)
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code not in ("404", "NoSuchKey", "NotFound"):
            raise
        # No hand-provisioned config: instantiate the template so the launch
        # proceeds (400s only when the template is missing too).
        _provision_config(user_id, agent, config_key)

    # Every cloud body is a site (docs/SITES.md §3.2), whether its config came
    # from the template or was provisioned by hand: enroll it and overlay the
    # site block onto the config the instance is about to fetch, with the SITE
    # token as its control-plane bearer — the operator bearer never boards an
    # instance. enrollKey ec2/<workerId> keeps one row per launch.
    site = json.loads(enroll_site({"_userId": user_id, "body": json.dumps({
        "agent": agent, "kind": "ec2", "displayName": "Cloud computer",
        "enrollKey": "ec2/{}".format(worker_id),
    })})["body"])
    _overlay_site_onto_config(config_key, site)

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

    if clear_inbox:
        S3.put_object(
            Bucket=BUCKET,
            Key=INBOX_KEY.format(user=user_id, agent=_key_slug(agent)),
            Body=b'{"version":1,"directives":[]}',
            ContentType="application/json",
        )

    tags = [
        {"Key": "Name", "Value": "fin-agent-{}".format(agent)},
        {"Key": "fin-agent", "Value": agent},
        {"Key": "fin-user", "Value": user_id},
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

    launched_at = _iso(instance.get("LaunchTime") or now)
    _record(worker_id, user_id, agent, instance["InstanceId"], instance_type, launched_at, idle_minutes, "control-plane", browser, site_id=site["siteId"])
    SITES_TABLE.update_item(
        Key={"siteId": site["siteId"]},
        UpdateExpression="SET workerId = :w",
        ExpressionAttributeValues={":w": worker_id},
    )
    return {
        "workerId": worker_id,
        "instanceId": instance["InstanceId"],
        "agent": agent,
        "instanceType": instance_type,
        "launchedAt": launched_at,
        "browser": browser,
    }


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

    user_id = event["_userId"]
    now = _now()
    existing = [w for w in _live_workers(user_id) if w.get("agent") == agent]
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

    # clear_inbox=False since sites Phase 1b (docs/SITES.md §6.5): a new body can
    # no longer discard messages another body will handle. Provisioned configs
    # carry supervision.inboxResetAtLaunch, so a fresh instance seeds the backlog
    # into its ledger instead of replaying it.
    result = _launch_worker(user_id, agent, instance_type, idle_minutes, browser, now, clear_inbox=False)
    LOG.info("launched %s for agent %s (%s%s)", result["instanceId"], agent, instance_type, ", browser" if browser else "")
    return _response(201, result)


def list_workers(event):
    now = _now()
    workers = _scan(FilterExpression="userId = :user", ExpressionAttributeValues={":user": event["_userId"]})
    workers.sort(key=lambda w: str(w.get("launchedAt") or ""), reverse=True)
    return _response(200, {"workers": [_decorate(w, now) for w in workers[:MAX_LIST_ITEMS]]})


def delete_worker(event, worker_id):
    worker = TABLE.get_item(Key={"workerId": worker_id}).get("Item")
    # 404, not 403, on someone else's worker — same "don't confirm existence
    # to a caller who shouldn't know about it" reasoning as every other
    # ownership check here. This was a live IDOR before: any authenticated
    # caller could terminate any worker, since nothing checked userId at all.
    if not worker or worker.get("userId") != event["_userId"]:
        raise ApiError(404, "no worker {}".format(worker_id))
    if worker.get("status") == "terminated":
        return _response(200, _decorate(worker, _now()))
    final = _terminate(worker, "api")
    LOG.info("terminated %s (worker %s)", worker.get("instanceId"), worker_id)
    return _response(200, _decorate(final, _now()))


def usage(event):
    now = _now()
    by_agent, by_type, unpriced = {}, {}, set()
    for worker in _scan(FilterExpression="userId = :user", ExpressionAttributeValues={":user": event["_userId"]}):
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
# The daemon's `update` command: a presigned GET of the published macOS binary
# plus its sha256 sidecar, verified before the atomic rename (docs/SITES.md §3.5).
BINARY_KINDS = ("agentdBinary",)
PRESIGN_KINDS = AGENT_KINDS + SUPERVISION_KINDS + BINARY_KINDS


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
    device_id8 = str(body.get("deviceId8") or "").strip().lower()

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

    user_id = event["_userId"]
    urls = {}
    for kind in kinds:
        if kind == "transcript":
            urls["transcriptGet"] = _presign("get_object", TRANSCRIPT_KEY.format(user=user_id, agent=slug))
        elif kind == "inbox":
            inbox_key = INBOX_KEY.format(user=user_id, agent=slug)
            urls["inboxGet"] = _presign("get_object", inbox_key)
            urls["inboxPut"] = _presign("put_object", inbox_key)
        elif kind == "status":
            urls["statusGet"] = _presign("get_object", STATUS_KEY.format(user=user_id, agent=slug))
        elif kind == "supervisionDirective":
            urls["supervisionDirectiveGet"] = _presign("get_object", SUPERVISION_DIRECTIVE_KEY.format(user=user_id))
        elif kind == "agentdBinary":
            urls["agentdBinaryGet"] = _presign("get_object", MACOS_BINARY_KEY)
            try:
                digest = S3.get_object(Bucket=BUCKET, Key=MACOS_BINARY_SHA256_KEY)["Body"].read().decode("utf-8", "replace")
                urls["agentdBinarySha256"] = digest.split()[0] if digest.split() else ""
            except ClientError:
                raise ApiError(404, "no published macOS daemon binary; run scripts/mac-fin-agentd/publish-binary.sh")
        elif kind == "supervisionStatus":
            # Absent deviceId8 => a pre-per-device client; hand it the flat key it
            # has always written to. Present-but-malformed is a real client bug and
            # still rejected, so a typo can't silently land in the legacy object.
            if not device_id8:
                urls["supervisionStatusPut"] = _presign(
                    "put_object", LEGACY_SUPERVISION_STATUS_KEY.format(user=user_id)
                )
            elif not DEVICE_ID_RE.match(device_id8):
                raise ApiError(400, "deviceId8 must be an 8-character lowercase hex device id")
            else:
                urls["supervisionStatusPut"] = _presign(
                    "put_object", DEVICE_STATUS_KEY.format(user=user_id, device=device_id8)
                )

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
    names = {"#platform": "platform", "#updated": "updatedAt", "#name": "deviceName", "#user": "userId"}
    values = {":platform": platform, ":updated": updated_at, ":user": event["_userId"]}
    expression = "SET #platform = :platform, #updated = :updated, #user = :user"
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
    """POST /notify — {"title", "body", "agent"?, "agentID"?, "originDeviceID8"?}:
    one APNs alert to every registered device. The response reports counts and
    APNs reason strings only — never a token, never the auth key, never the JWT."""
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

    # Neither is secret and both are best-effort: a malformed value here just
    # means the eventual tap can't deep-link (same tolerant-parse philosophy as
    # the app's own AgentSignalSubscriber.openTarget), never a hard failure of
    # the push itself.
    agent_id = str(body.get("agentID") or "").strip()
    try:
        agent_id = str(uuid.UUID(agent_id)) if agent_id else ""
    except ValueError:
        agent_id = ""
    origin_device_id8 = str(body.get("originDeviceID8") or "").strip()
    if not DEVICE_ID8.match(origin_device_id8):
        origin_device_id8 = ""

    # Was unscoped — every registered device token, account-wide — a real
    # cross-tenant push leak once there is more than one user. Every device
    # token is stamped with its owner's userId by put_device_token now.
    rows = _scan(
        table=DEVICE_TOKENS_TABLE,
        FilterExpression="userId = :user",
        ExpressionAttributeValues={":user": event["_userId"]},
    )
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
    if agent_id:
        # Same "fin" dict shape a local (on-device) notification's userInfo
        # carries — AgentNotificationService.didReceive reads either one the
        # same way. originDeviceID8 tells it this push did NOT originate on
        # the receiving device, so a tap routes to the remote conversation
        # instead of assuming local origin (see AgentNotificationService.swift).
        payload["fin"] = {"agentID": agent_id}
        if origin_device_id8:
            payload["fin"]["originDeviceID8"] = origin_device_id8

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


def _secret_name(user_id, scope, service):
    return "{}/{}/{}".format(SECRET_PREFIX.format(user=user_id), scope, service)


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
    for field in SECRET_FIELDS:
        raw = body.get(field)
        if raw is None:
            continue
        if not isinstance(raw, str) or not raw.strip():
            raise ApiError(400, "{} must be a non-empty string".format(field))
        if len(raw.encode("utf-8")) > MAX_SECRET_FIELD_BYTES:
            raise ApiError(400, "{} exceeds {} bytes".format(field, MAX_SECRET_FIELD_BYTES))
        fields[field] = raw
    if "value" not in fields and "privateKey" not in fields:
        raise ApiError(400, "value (or privateKey) is required")

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

    name = _secret_name(event["_userId"], scope, service)
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
    prefix = SECRET_PREFIX.format(user=event["_userId"]) + "/"
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
        # users/{user}/fin/service-creds/{scope}/{service} — service and scope
        # are the last two segments; tags are the primary source (set by
        # put_secret on every write), this is only a fallback for an entry
        # somehow missing them.
        name_parts = str(entry.get("Name") or "").split("/")
        row = {
            "service": tags.get("fin-service") or (name_parts[-1] if len(name_parts) > 1 else ""),
            "agentScope": tags.get("fin-scope") or (name_parts[-2] if len(name_parts) > 2 else ""),
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
    name = _secret_name(event["_userId"], scope, service)
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


def _read_status(user_id, agent):
    """The agent's status document, or None when it is missing or unparseable."""
    try:
        raw = S3.get_object(Bucket=BUCKET, Key=STATUS_KEY.format(user=user_id, agent=_key_slug(agent)))["Body"].read()
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

    # A worker that is a site reports through its heartbeat, which is fresher
    # and richer than the status object: alive and working is never idle,
    # and a lease three beats stale IS the "status stale" verdict.
    site = _read_site(worker.get("siteId") or "") if worker.get("siteId") else None
    if site:
        if _site_is_live(site, now):
            if site.get("state") in ("working", "needs-input"):
                return None
            beat = _parse_iso(site.get("lastHeartbeatAt")) or launched
            if now - beat > idle:
                return "site idle since {}".format(_iso(beat))
        elif now - launched > timedelta(minutes=BOOT_GRACE_MINUTES) and site.get("lastHeartbeatAt"):
            lease = _parse_iso(site.get("leaseUntil"))
            if lease is not None and now - lease > timedelta(seconds=3 * SITE_LEASE_SECONDS):
                return "site lease lapsed at {}".format(_iso(lease))

    status = _read_status(str(worker.get("userId") or ""), str(worker.get("agent") or ""))
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
        # refreshes it every poll — so the clock normally runs from the last real
        # turn, or from launch for a worker that has never taken one. But a daemon
        # with an armed heartbeat and nothing left to pursue keeps calling that
        # timer forward too — every reflective beat, empty or not, still stamps
        # last_turn_at — so cost never stops accruing for a worker that has quietly
        # run out of mission. When the daemon reports has_open_goals == False, use
        # no_goals_since instead: it holds steady across heartbeats until a goal
        # reopens, so idle time actually accumulates. Absent (older daemon, or no
        # goals ledger loaded) falls back to the original last_turn_at behavior.
        if status.get("has_open_goals") is False:
            since = _parse_iso(status.get("no_goals_since")) or launched
            reason = "no open goals since {}"
        else:
            since = _parse_iso(status.get("last_turn_at")) or launched
            reason = str(status.get("state")) + " since {}"
        if now - since > idle:
            return reason.format(_iso(since))

    return None


def _adopt(now, known_instance_ids):
    """Gives hand-launched instances a record so the sweep can reach them too.
    An instance from before multi-tenancy (or launched by hand without a
    fin-user tag) has no owner we can safely infer — adopting it under a
    guessed userId would let it read/write into the wrong prefix — so it's
    skipped and logged instead, for a human to sort out via the console."""
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
                user_id = _tag(instance, "fin-user")
                if not user_id:
                    LOG.warning("skipping adoption of %s: no fin-user tag, owner unknown", instance_id)
                    continue
                idle_tag = _tag(instance, "fin-idle-minutes")
                worker = _record(
                    str(uuid.uuid4()),
                    user_id,
                    _tag(instance, "fin-agent") or "unknown",
                    instance_id,
                    instance.get("InstanceType", "unknown"),
                    _iso(instance.get("LaunchTime") or now),
                    int(idle_tag) if idle_tag.isdigit() else DEFAULT_IDLE_MINUTES,
                    "adopted",
                )
                adopted.append(worker)
                LOG.info("adopted %s for agent %s (user %s)", instance_id, worker["agent"], user_id)
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

    stale_sites = _mark_stale_sites(now)

    return {
        "generatedAt": _iso(now),
        "checked": len(live),
        "terminated": terminated,
        "reconciled": reconciled,
        "staleSites": stale_sites,
        "adopted": [{"workerId": w["workerId"], "agent": w["agent"], "instanceId": w["instanceId"]} for w in adopted],
    }


# --- cloud transcript (hourly S3 chunks) --------------------------------------
#
# The daemon's transcript used to be one rolling object (TRANSCRIPT_KEY above),
# fully overwritten on every flush — a restart starts that ring empty, so the
# next flush truncates the whole history ("the restart-overwrites-history bug",
# documented in scripts/mac-fin-agentd/provision-config.sh, never fixed there).
# Chunking by UTC hour means a restart only affects the CURRENT hour's
# in-flight chunk; every prior hour is already durable in S3 and can never be
# truncated. Each PUT is the whole hour's accumulated lines (the daemon's own
# in-memory ring already holds them) — same "the caller sends the whole
# document" shape as every other S3 write in this file, just partitioned by
# hour instead of by agent alone.

TRANSCRIPT_HOUR = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}$")
MAX_TRANSCRIPT_CHUNK_BYTES = 2 * 1024 * 1024
MAX_TRANSCRIPT_CHUNK_LINES = 5000


def put_transcript_chunk(event):
    """PUT /transcript-chunk — {"agent", "hour": "yyyy-MM-ddTHH", "lines": [str,...]}.
    Merges into the named hour's chunk (see _merge_transcript_lines)."""
    body = _body(event)
    agent = str(body.get("agent") or "").strip()
    if not AGENT_NAME.match(agent):
        raise ApiError(400, "agent must match [A-Za-z0-9][A-Za-z0-9._-]{0,62}")
    hour = str(body.get("hour") or "").strip()
    if not TRANSCRIPT_HOUR.match(hour):
        raise ApiError(400, "hour must match yyyy-MM-ddTHH (UTC)")
    lines = body.get("lines")
    if not isinstance(lines, list) or not all(isinstance(line, str) for line in lines):
        raise ApiError(400, "lines must be an array of strings")
    if len(lines) > MAX_TRANSCRIPT_CHUNK_LINES:
        raise ApiError(400, "lines exceeds {} entries".format(MAX_TRANSCRIPT_CHUNK_LINES))
    encoded = "\n".join(lines).encode("utf-8")
    if len(encoded) > MAX_TRANSCRIPT_CHUNK_BYTES:
        raise ApiError(413, "chunk exceeds {} bytes".format(MAX_TRANSCRIPT_CHUNK_BYTES))
    key = TRANSCRIPT_CHUNK_KEY.format(user=event["_userId"], agent=_key_slug(agent), hour=hour)
    # MERGE, never replace. The daemon's ring is per process, so a restart used to
    # PUT an hour containing only the lines since the restart — and every trace
    # from earlier in that hour was gone (live, 2026-09-12: a whole turn's
    # reasoning and tool calls vanished after two restarts). Lines carry ids;
    # the stored hour keeps what it had and takes what is new, newest kept
    # when the cap bites.
    merged = _merge_transcript_lines(_get_transcript_chunk(event["_userId"], agent, hour), lines)
    encoded = "\n".join(merged).encode("utf-8")
    S3.put_object(Bucket=BUCKET, Key=key, Body=encoded, ContentType="application/json")
    return _response(200, {"agent": agent, "hour": hour, "lines": len(merged)})


def _transcript_line_key(line):
    try:
        obj = json.loads(line)
    except ValueError:
        return line
    return obj.get("id") or line if isinstance(obj, dict) else line


def _transcript_line_sort_key(line):
    try:
        obj = json.loads(line)
    except ValueError:
        return ("", "", 0)
    if not isinstance(obj, dict):
        return ("", "", 0)
    return (str(obj.get("timestamp") or ""), str(obj.get("run_id") or ""), int(obj.get("sequence") or 0))


def _merge_transcript_lines(existing, incoming):
    """Union by line id (a line with no parseable id is keyed by its text), in
    (timestamp, run_id, sequence) order — the app's own merge order — capped at
    MAX_TRANSCRIPT_CHUNK_LINES with the OLDEST dropped, since the newest lines
    are the ones a reader opening the console is waiting for."""
    seen = {}
    for line in existing + incoming:
        seen[_transcript_line_key(line)] = line
    merged = sorted(seen.values(), key=_transcript_line_sort_key)
    if len(merged) > MAX_TRANSCRIPT_CHUNK_LINES:
        merged = merged[-MAX_TRANSCRIPT_CHUNK_LINES:]
    return merged


def _list_transcript_hours(user_id, agent):
    prefix = "users/{}/fin/transcripts/{}/".format(user_id, _key_slug(agent))
    hours, token = [], None
    while True:
        kwargs = {"Bucket": BUCKET, "Prefix": prefix, "MaxKeys": 1000}
        if token:
            kwargs["ContinuationToken"] = token
        page = S3.list_objects_v2(**kwargs)
        for entry in page.get("Contents", []):
            name = entry["Key"][len(prefix):]
            if name.endswith(".jsonl"):
                hours.append(name[:-len(".jsonl")])
        token = page.get("NextContinuationToken")
        if not token:
            break
    return sorted(hours)


def _get_transcript_chunk(user_id, agent, hour):
    key = TRANSCRIPT_CHUNK_KEY.format(user=user_id, agent=_key_slug(agent), hour=hour)
    try:
        raw = S3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code in ("404", "NoSuchKey", "NoSuchBucket", "AccessDenied"):
            return []
        raise
    text = raw.decode("utf-8", "replace")
    return [line for line in text.split("\n") if line.strip()]


def get_transcript_chunks(event):
    """GET /transcript-chunks?agent=&hour= — omit hour for the hour list plus
    the latest chunk's lines (the "load the recent conversation quickly" case);
    pass hour to page in one specific earlier chunk."""
    params = event.get("queryStringParameters") or {}
    agent = str(params.get("agent") or "").strip()
    if not AGENT_NAME.match(agent):
        raise ApiError(400, "agent must match [A-Za-z0-9][A-Za-z0-9._-]{0,62}")
    user_id = event["_userId"]
    hours = _list_transcript_hours(user_id, agent)
    requested_hour = str(params.get("hour") or "").strip()
    if requested_hour:
        if not TRANSCRIPT_HOUR.match(requested_hour):
            raise ApiError(400, "hour must match yyyy-MM-ddTHH (UTC)")
        return _response(200, {
            "agent": agent, "hours": hours,
            "chunk": {"hour": requested_hour, "lines": _get_transcript_chunk(user_id, agent, requested_hour)},
        })
    latest = hours[-1] if hours else None
    return _response(200, {
        "agent": agent, "hours": hours,
        "chunk": {"hour": latest, "lines": _get_transcript_chunk(user_id, agent, latest)} if latest else None,
    })


# --- agent memory (S3 journal, source of truth for cross-device sync) --------
#
# One JSON document per agent: a collection of memory entries, atomically
# rewritten on every save — "a collection of journals that are atomically
# written," not one unbounded append-only stream. Both the app (its own
# `remember` calls) and the daemon (a daemon-hosted conversation's `remember`
# calls) push entries here and pull the whole document to merge into their own
# local store — this Lambda is the one place both sides agree on, so client
# and cloud agents stay in sync.

MAX_MEMORY_ENTRIES = 2000
MAX_MEMORY_FIELD_BYTES = 8 * 1024
MAX_MEMORY_DOC_BYTES = 4 * 1024 * 1024


def _read_memory_document(user_id, agent):
    key = MEMORY_KEY.format(user=user_id, agent=_key_slug(agent))
    try:
        raw = S3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code in ("404", "NoSuchKey", "NoSuchBucket", "AccessDenied"):
            return {"version": 1, "entries": []}
        raise
    try:
        document = json.loads(raw)
    except ValueError:
        LOG.warning("memory document for %s is not JSON", agent)
        return {"version": 1, "entries": []}
    if not isinstance(document, dict) or not isinstance(document.get("entries"), list):
        return {"version": 1, "entries": []}
    return document


def _require_memory_field(body, field, max_bytes=None):
    value = body.get(field)
    if not isinstance(value, str) or not value.strip():
        raise ApiError(400, "{} must be a non-empty string".format(field))
    if max_bytes is not None and len(value.encode("utf-8")) > max_bytes:
        raise ApiError(400, "{} exceeds {} bytes".format(field, max_bytes))
    return value


def put_memory_entry(event):
    """POST /memory — one entry, upserted by id into the agent's document.
    {"agent", "id", "agentId"?, "conversationId"?, "kind", "title", "content",
    "tags"?, "originDevice8"?, "createdAt", "updatedAt"}. Last-writer-wins on a
    same-id race — the same accepted risk this file already takes for the
    inbox document (CloudAgentChannel.appendedInboxDocument on the app side);
    at Fin's current single-account scale a genuine collision is vanishingly
    rare and, worst case, just loses one duplicate save, not data."""
    body = _body(event)
    agent = str(body.get("agent") or "").strip()
    if not AGENT_NAME.match(agent):
        raise ApiError(400, "agent must match [A-Za-z0-9][A-Za-z0-9._-]{0,62}")
    entry_id = _require_memory_field(body, "id", max_bytes=200)
    kind = str(body.get("kind") or "episodic").strip()
    if kind not in ("episodic", "cumulative"):
        raise ApiError(400, "kind must be 'episodic' or 'cumulative'")
    title = _require_memory_field(body, "title", max_bytes=MAX_MEMORY_FIELD_BYTES)
    content = _require_memory_field(body, "content", max_bytes=MAX_MEMORY_FIELD_BYTES)
    tags = body.get("tags")
    if tags is not None and not isinstance(tags, str):
        raise ApiError(400, "tags must be a string")
    created_at = body.get("createdAt")
    if _parse_iso(created_at) is None:
        raise ApiError(400, "createdAt must be an ISO8601 timestamp")
    updated_at = body.get("updatedAt") or created_at
    if _parse_iso(updated_at) is None:
        raise ApiError(400, "updatedAt must be an ISO8601 timestamp")
    agent_id = body.get("agentId")
    if agent_id is not None and not isinstance(agent_id, str):
        raise ApiError(400, "agentId must be a string or null")
    conversation_id = body.get("conversationId")
    if conversation_id is not None and not isinstance(conversation_id, str):
        raise ApiError(400, "conversationId must be a string or null")
    origin_device8 = body.get("originDevice8")
    if origin_device8 is not None and not DEVICE_ID8.match(str(origin_device8)):
        origin_device8 = None

    entry = {
        "id": entry_id, "agentId": agent_id, "conversationId": conversation_id,
        "kind": kind, "title": title, "content": content, "tags": tags or "",
        "originDevice8": origin_device8, "createdAt": created_at, "updatedAt": updated_at,
    }

    document = _read_memory_document(event["_userId"], agent)
    entries = [e for e in document["entries"] if e.get("id") != entry_id]
    entries.append(entry)
    entries.sort(key=lambda e: e.get("updatedAt") or "")
    if len(entries) > MAX_MEMORY_ENTRIES:
        entries = entries[-MAX_MEMORY_ENTRIES:]
    document = {"version": 1, "updatedAt": _iso(_now()), "entries": entries}
    encoded = json.dumps(document, sort_keys=True).encode("utf-8")
    if len(encoded) > MAX_MEMORY_DOC_BYTES:
        raise ApiError(413, "memory document exceeds {} bytes".format(MAX_MEMORY_DOC_BYTES))
    S3.put_object(
        Bucket=BUCKET, Key=MEMORY_KEY.format(user=event["_userId"], agent=_key_slug(agent)),
        Body=encoded, ContentType="application/json",
    )
    LOG.info("upserted memory entry %s for %s", entry_id, agent)
    return _response(200, {"agent": agent, "id": entry_id, "entries": len(entries)})


def get_memory(event):
    """GET /memory?agent=&since= — the whole document, or entries updated at or
    after `since` (ISO8601) when given."""
    params = event.get("queryStringParameters") or {}
    agent = str(params.get("agent") or "").strip()
    if not AGENT_NAME.match(agent):
        raise ApiError(400, "agent must match [A-Za-z0-9][A-Za-z0-9._-]{0,62}")
    document = _read_memory_document(event["_userId"], agent)
    since = _parse_iso(params.get("since"))
    entries = document["entries"]
    if since is not None:
        entries = [e for e in entries if (_parse_iso(e.get("updatedAt")) or _now()) >= since]
    return _response(200, {"agent": agent, "entries": entries})


# --- cumulative profile (one shared, cross-agent summary) --------------------
#
# The single distilled "who is this user" digest — tasks, goals, preferences,
# style — injected into every agent's system prompt and shown in the app's
# memory view. Unlike the per-agent episodic document above, there is exactly
# ONE of these per ACCOUNT (not per agent — still per-user): cross-agent and
# cross-device, so a fact learned on the client and one learned by a
# cloud-hosted agent converge on the same profile. "S3 as source of truth"
# applies here too — this document, plus the claim lock below, is what lets
# the client and cloud agents coordinate who actually runs the (model-driven,
# so not-cheap) compaction pass.

PROFILE_KEY = "users/{user}/fin/memory/_profile.json"
PROFILE_LOCK_KEY = "users/{user}/fin/memory/_profile.lock"
MAX_PROFILE_BYTES = 4 * 1024
LOCK_STALE_AFTER_SECONDS = 5 * 60


def get_memory_profile(event):
    """GET /memory/profile — the shared cumulative profile. Absent is a valid,
    common state (nothing consolidated yet), not an error."""
    try:
        raw = S3.get_object(Bucket=BUCKET, Key=PROFILE_KEY.format(user=event["_userId"]))["Body"].read()
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code in ("404", "NoSuchKey", "NoSuchBucket", "AccessDenied"):
            return _response(200, {"content": "", "updatedAt": None})
        raise
    try:
        document = json.loads(raw)
    except ValueError:
        document = None
    if not isinstance(document, dict):
        return _response(200, {"content": "", "updatedAt": None})
    return _response(200, {
        "content": document.get("content") or "",
        "updatedAt": document.get("updatedAt"),
    })


def put_memory_profile(event):
    """PUT /memory/profile — {"content"} replaces the profile wholesale. Last-writer-
    wins, same accepted risk `put_memory_entry` already documents — the claim lock
    keeps concurrent COMPACTION passes from racing, but a plain profile write outside
    that flow (rare) can still land at any time."""
    body = _body(event)
    content = body.get("content")
    if not isinstance(content, str):
        raise ApiError(400, "content must be a string")
    if len(content.encode("utf-8")) > MAX_PROFILE_BYTES:
        raise ApiError(400, "content exceeds {} bytes".format(MAX_PROFILE_BYTES))
    document = {"content": content, "updatedAt": _iso(_now())}
    S3.put_object(
        Bucket=BUCKET, Key=PROFILE_KEY.format(user=event["_userId"]),
        Body=json.dumps(document, sort_keys=True).encode("utf-8"),
        ContentType="application/json",
    )
    return _response(200, document)


def _read_lock(key):
    try:
        raw = S3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code in ("404", "NoSuchKey", "NoSuchBucket", "AccessDenied"):
            return None
        raise
    try:
        lock = json.loads(raw)
    except ValueError:
        return None
    return lock if isinstance(lock, dict) else None


def _claim_lock(key, holder):
    """Atomic claim via conditional PUT (IfNoneMatch, the same primitive
    `_provision_config` already uses for config auto-provisioning). A claim that
    loses the race is told who holds it (409), and may retry once the holder's
    claim is older than LOCK_STALE_AFTER_SECONDS — a crashed or slow holder must
    not wedge every other runner forever. Shared by the memory-profile lock and
    the per-agent inbox lock below; both are pure S3-metadata coordination, no
    model reasoning involved on either end — a holder is just an id string.
    """
    document = {"holder": holder, "claimedAt": _iso(_now())}
    encoded = json.dumps(document, sort_keys=True).encode("utf-8")
    try:
        S3.put_object(
            Bucket=BUCKET, Key=key, Body=encoded,
            ContentType="application/json", IfNoneMatch="*",
        )
        return document
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code not in ("PreconditionFailed", "ConditionalRequestConflict"):
            raise

    existing = _read_lock(key)
    claimed_at = existing and _parse_iso(existing.get("claimedAt"))
    if claimed_at is not None and (_now() - claimed_at).total_seconds() > LOCK_STALE_AFTER_SECONDS:
        # Stale — reclaim unconditionally. A second caller racing THIS reclaim is
        # the same accepted last-writer-wins risk as everywhere else in this file,
        # narrowed to the rare case of two callers both waiting out the same TTL.
        S3.put_object(Bucket=BUCKET, Key=key, Body=encoded, ContentType="application/json")
        return document
    raise ApiError(409, "locked by {}".format((existing or {}).get("holder") or "another runner"))


def _release_lock(key):
    try:
        S3.delete_object(Bucket=BUCKET, Key=key)
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code not in ("404", "NoSuchKey", "NoSuchBucket"):
            raise


def claim_memory_profile_lock(event):
    """PUT /memory/profile/lock — {"holder"}. See `_claim_lock`."""
    body = _body(event)
    holder = str(body.get("holder") or "").strip()
    if not holder:
        raise ApiError(400, "holder must be a non-empty string")
    return _response(200, _claim_lock(PROFILE_LOCK_KEY.format(user=event["_userId"]), holder))


def release_memory_profile_lock(event):
    """DELETE /memory/profile/lock — unconditional; called by whoever finishes
    (success or failure) so the next attempt doesn't wait out the full TTL."""
    _release_lock(PROFILE_LOCK_KEY.format(user=event["_userId"]))
    return _response(200, {"released": True})


# --- inbox coordination (per-agent claim lock) --------------------------------
#
# Multiple sites (the app's Mac-resident daemon, a hand-launched cloud worker,
# an auto-woken one below) can all be alive and polling the SAME agent's inbox
# at once — each site's own "already answered this" ledger lives on its own
# disk (`DaemonDirectiveClient.appliedIDs`), invisible to every other site, so
# without coordination two sites could both answer the same message. Same
# fix as the memory profile's compaction lock, generalized to one lock per
# agent: whoever claims `fin/inbox/{agent}.lock` first drives that message;
# everyone else backs off and lets them, checking again once the claim
# releases or goes stale. Entirely S3-metadata mechanics — a holder is just an
# id string a site writes about itself, nothing here ever asks a model
# anything.


def claim_inbox_lock(event, agent):
    """PUT /inbox/{agent}/lock — {"holder"}. See `_claim_lock`."""
    body = _body(event)
    holder = str(body.get("holder") or "").strip()
    if not holder:
        raise ApiError(400, "holder must be a non-empty string")
    key = INBOX_LOCK_KEY.format(user=event["_userId"], agent=_key_slug(agent))
    return _response(200, _claim_lock(key, holder))


def release_inbox_lock(event, agent):
    """DELETE /inbox/{agent}/lock — unconditional; call after every claimed
    turn, success or failure, so the next site doesn't wait out the TTL."""
    _release_lock(INBOX_LOCK_KEY.format(user=event["_userId"], agent=_key_slug(agent)))
    return _response(200, {"released": True})


# --- wake sweep (auto-launch when nothing is answering) -----------------------
#
# The idle sweep (above) answers "is a worker running for no reason"; this is
# its mirror: "is a message sitting for no worker". Without it, a user with no
# always-on computer of their own — the whole point of the cloud harness —
# sends a voice message that lands in the inbox and then just sits there until
# they remember to open the app and tap "Start Worker" by hand. Scheduled on
# its own, tighter EventBridge cadence than the idle sweep (`fin-worker-wake`,
# ~1 minute): Lambda invocations are effectively free at this volume, and
# responsiveness — how long a message waits for a reply — is what this
# schedule buys, not idle-cost precision.

WAKE_GRACE_MINUTES = 3
# Past this many hours of silence, stop trying to auto-launch and tell the
# user instead — found live: an agent with an 11-day-old inbox message and no
# active site would otherwise get a real EC2 instance launched for what reads
# like abandoned test debris. Under the ceiling, a message gets a prompt,
# unattended reply (the whole point, for someone with no spare computer);
# past it, a human decides whether it's still worth answering.
WAKE_NOTIFY_CEILING_HOURS = 72
INBOX_NOTIFIED_KEY = "users/{user}/fin/inbox/{agent}.notified"


def _lock_is_stale(lock, now):
    if lock is None:
        return True
    claimed_at = _parse_iso(lock.get("claimedAt"))
    return claimed_at is None or (now - claimed_at).total_seconds() > LOCK_STALE_AFTER_SECONDS


def _wake_decision(has_live_worker, lock, inbox_last_modified, status, now):
    """Pure: what should the wake sweep do about this agent right now? Every
    input is already-fetched — no I/O, no model call, so this is directly
    unit-testable without touching AWS. Returns an (action, detail) pair:
    action is "wake" (launch a worker), "notify" (too stale to auto-launch —
    tell the user instead), or None (nothing to do); detail is a one-line
    reason, or None. Deliberately conservative: any one signal that "someone
    already has this" wins.

    - has_live_worker: an EC2 worker is already recorded live for this agent —
      trust it to answer; the idle sweep, not this, is what retires it.
    - lock: the current `fin/inbox/{agent}.lock` document, or None if absent.
      A non-stale claim (checked via `_lock_is_stale`) means SOME site — not
      necessarily an EC2 worker — is actively driving this agent's inbox
      right now.
    - inbox_last_modified: when the inbox object was last written — a proxy
      for "when did the newest message arrive" (every send is a whole-
      document PUT, so the object's own S3 timestamp needs no schema change
      to carry this). None means no inbox exists yet — nothing to wake for.
    - status: the agent's status document (`_read_status`'s shape), for the
      "already answered" check — a turn that completed at or after the inbox
      was last touched means whoever answered it already has, even though
      nothing currently holds the lock (the common case: a healthy site
      claims, answers, and releases within seconds, long before this sweep's
      next tick).
    """
    if has_live_worker or inbox_last_modified is None:
        return (None, None)
    if not _lock_is_stale(lock, now):
        return (None, None)
    age = now - inbox_last_modified
    if age < timedelta(minutes=WAKE_GRACE_MINUTES):
        return (None, None)
    last_turn = status and _parse_iso(status.get("last_turn_at"))
    if last_turn is not None and last_turn >= inbox_last_modified:
        return (None, None)
    if age > timedelta(hours=WAKE_NOTIFY_CEILING_HOURS):
        return ("notify", "unanswered inbox message idle for over {} hours, no live worker or active site".format(
            WAKE_NOTIFY_CEILING_HOURS
        ))
    return ("wake", "unanswered inbox message, no live worker or active site")


def _inbox_candidates():
    """Every (userId, agent) with an inbox object, the agent's most-recently-
    stated name (proper case, read from the newest directive's own `agent`
    field — the filename itself only has the lowercased slug, and DynamoDB's
    409 check in `create_worker` compares agent names case-sensitively, so a
    wake-launched worker recorded under the wrong case would silently let a
    later manual "Start Worker" tap launch a duplicate) and the object's
    LastModified. userId is parsed straight out of the key path
    (users/{userId}/fin/inbox/{agent}.json) — this walks every user's inbox,
    so it's only ever called from the schedule-triggered wake(), never a
    per-request route (those already have one userId from _authorize).
    """
    candidates = []
    paginator = S3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=BUCKET, Prefix="users/"):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if not key.endswith(".json") or "/fin/inbox/" not in key:
                continue
            parts = key.split("/")
            if len(parts) != 5 or parts[0] != "users" or parts[2] != "fin" or parts[3] != "inbox":
                continue
            user_id = parts[1]
            try:
                raw = S3.get_object(Bucket=BUCKET, Key=key)
                body = raw["Body"].read()
                last_modified = raw["LastModified"]
            except ClientError:
                continue
            try:
                document = json.loads(body)
            except ValueError:
                continue
            directives = document.get("directives") if isinstance(document, dict) else None
            agent = None
            if isinstance(directives, list):
                for entry in reversed(directives):
                    if isinstance(entry, dict) and entry.get("agent"):
                        agent = str(entry["agent"])
                        break
            if not agent:
                continue
            candidates.append((user_id, agent, last_modified))
    return candidates


def _already_notified(user_id, agent, inbox_last_modified):
    """Surfaced once, then sit quiet — the same discipline the Mission
    ledger's own conduct rules already use for a surfaced blocker: a stale
    inbox message that gets one push, not one every minute forever. A NEWER
    message arriving resets this (the marker's own `forLastModified` goes
    stale relative to the fresh inbox timestamp), so a genuinely new stale
    episode still gets its own alert."""
    marker = _read_lock(INBOX_NOTIFIED_KEY.format(user=user_id, agent=_key_slug(agent)))
    if marker is None:
        return False
    notified_for = _parse_iso(marker.get("forLastModified"))
    return notified_for is not None and notified_for >= inbox_last_modified


def _mark_notified(user_id, agent, inbox_last_modified):
    S3.put_object(
        Bucket=BUCKET, Key=INBOX_NOTIFIED_KEY.format(user=user_id, agent=_key_slug(agent)),
        Body=json.dumps({"forLastModified": _iso(inbox_last_modified)}, sort_keys=True).encode("utf-8"),
        ContentType="application/json",
    )


def _merged_last_turn_at(candidates):
    """Pure: the most recent of any last_turn_at values known for an agent, or
    None if none are known. Split out from `_known_last_turn_ats` so the
    actual decision math (which timestamp wins) is unit-testable without S3.

    Why "merge" instead of "the" one status: an agent can be answered by
    MULTIPLE kinds of site — a cloud-launched EC2 worker (writes the legacy
    flat STATUS_KEY, see `_provision_config`) or a resident non-cloud site
    like the owner's Mac daemon (writes `fin/sites/{agent}/{site8}/
    status.json`, see scripts/mac-fin-agentd/provision-config.sh). The wake
    sweep must not conclude "nobody has this" just because the source IT
    happened to check is stale or missing — a live incident (2026-09-10)
    showed the sweep re-launching a redundant cloud worker for "Fin" every
    ~10-20 minutes for 10+ hours because it only ever read the flat key
    (frozen since 04:10, an old device), never noticing the resident Mac site
    had already answered everything as recently as its own last real turn."""
    known = [c for c in candidates if c is not None]
    return max(known) if known else None


def _known_last_turn_ats(user_id, agent):
    """I/O: every last_turn_at this control plane can currently see for
    (user_id, agent) — the legacy flat status a cloud-launched worker writes
    (`_read_status`/`STATUS_KEY`), plus every per-site status document under
    `fin/sites/{agent}/*/status.json` (a resident Mac daemon today; any
    future non-cloud site the same way). Not unit tested directly — an I/O
    wrapper verified by hand-curl like every other AWS-touching function in
    this file (see module docstring); `_merged_last_turn_at` is where the
    actual decision logic lives and IS unit tested."""
    values = []
    legacy = _read_status(user_id, agent)
    if legacy:
        values.append(_parse_iso(legacy.get("last_turn_at")))
    prefix = "users/{}/fin/sites/{}/".format(user_id, _key_slug(agent))
    paginator = S3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=BUCKET, Prefix=prefix):
        for obj in page.get("Contents", []):
            if not obj["Key"].endswith("/status.json"):
                continue
            try:
                raw = S3.get_object(Bucket=BUCKET, Key=obj["Key"])["Body"].read()
                site_status = json.loads(raw)
            except (ClientError, ValueError):
                continue
            if isinstance(site_status, dict):
                values.append(_parse_iso(site_status.get("last_turn_at")))
    return values


def _notify_stale_inbox(user_id, agent, detail):
    synthetic_event = {"_userId": user_id, "body": json.dumps({
        "title": "{} has an unanswered message".format(agent),
        "body": "{} — open the app to answer it or start a worker by hand.".format(detail),
        "agent": agent,
    })}
    try:
        notify(synthetic_event)
    except Exception:  # noqa: BLE001 - one agent's push failure must never
        # abort the sweep for every other agent still waiting to be checked.
        # No device tokens, APNs not configured, a transient APNs error — the
        # marker below still gets written so this doesn't retry every tick.
        LOG.exception("wake sweep: notify failed for agent %s", agent)


def wake(_event=None):
    now = _now()
    live_worker_keys = {
        (w.get("userId"), _key_slug(w["agent"])) for w in _live_workers() if w.get("agent") and w.get("userId")
    }
    checked, launched, notified = [], [], []
    # Phase 3: the queue is fin-messages, not the inbox object. A queued row
    # nobody has claimed, with no live SITE of any kind for the agent (a resident
    # Mac counts — the 2026-09-10 relaunch loop was exactly this blindness), is
    # what wakes a cloud body. `_wake_decision` is unchanged: "has a live
    # worker" now means "has any live body", the lock is gone, and the row's
    # createdAt plays the inbox's LastModified.
    for user_id, agent, oldest_queued_at in _queued_message_candidates(now):
        checked.append(agent)
        try:
            slug = _key_slug(agent)
            has_live_body = (user_id, slug) in live_worker_keys or _any_live_site(user_id, agent, now)
            action, detail = _wake_decision(has_live_body, None, oldest_queued_at, None, now)
            last_modified = oldest_queued_at
            if action == "wake":
                result = _launch_worker(
                    user_id, agent, DEFAULT_INSTANCE_TYPE, DEFAULT_IDLE_MINUTES, False, now, clear_inbox=False
                )
                LOG.info("woke %s for agent %s: %s", result["instanceId"], agent, detail)
                launched.append({"agent": agent, "instanceId": result["instanceId"], "detail": detail})
            elif action == "notify":
                if not _already_notified(user_id, agent, last_modified):
                    _notify_stale_inbox(user_id, agent, detail)
                    _mark_notified(user_id, agent, last_modified)
                    LOG.info("notified about stale inbox for agent %s: %s", agent, detail)
                    notified.append({"agent": agent, "detail": detail})
        except Exception:  # noqa: BLE001 - one agent's failure (EC2 throttled,
            # a malformed status object, ...) must never stop the sweep from
            # checking every other agent this tick.
            LOG.exception("wake sweep: failed while checking agent %s", agent)
    return {"generatedAt": _iso(now), "checked": checked, "launched": launched, "notified": notified}


# --- artifacts (per-account plain-text file store) ----------------------------
#
# "a second filesystem apart from the iOS native one" — one flat, agent-
# writable space of plain text files (no binary/MIME handling: "other
# artifacts are arbitrary text files" is the whole v1 scope). One prefix for
# the whole Fin account — no multi-tenant user/auth system exists to scope
# this further at the deployment's current single-account scale.

ARTIFACT_PATH = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,300}$")
MAX_ARTIFACT_BYTES = 1024 * 1024
MAX_ARTIFACT_LIST_ITEMS = 1000


def _require_artifact_path(path):
    if not path or ".." in path.split("/") or not ARTIFACT_PATH.match(path):
        raise ApiError(400, "path must match [A-Za-z0-9][A-Za-z0-9._/-]{0,300} with no .. segment")
    return path


def list_artifacts(event):
    """GET /artifacts — every path in the CALLER's artifacts folder, sorted."""
    prefix = _artifact_prefix(event["_userId"])
    items, token = [], None
    while len(items) < MAX_ARTIFACT_LIST_ITEMS:
        kwargs = {
            "Bucket": BUCKET, "Prefix": prefix,
            "MaxKeys": min(1000, MAX_ARTIFACT_LIST_ITEMS - len(items)),
        }
        if token:
            kwargs["ContinuationToken"] = token
        page = S3.list_objects_v2(**kwargs)
        for entry in page.get("Contents", []):
            items.append({
                "path": entry["Key"][len(prefix):],
                "size": entry["Size"],
                "updatedAt": _iso(entry["LastModified"]),
            })
        token = page.get("NextContinuationToken")
        if not token:
            break
    items.sort(key=lambda i: i["path"])
    return _response(200, {"artifacts": items})


def get_artifact(event, path):
    _require_artifact_path(path)
    try:
        obj = S3.get_object(Bucket=BUCKET, Key=_artifact_prefix(event["_userId"]) + path)
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code in ("404", "NoSuchKey", "NoSuchBucket"):
            raise ApiError(404, "no artifact at {}".format(path))
        raise
    content = obj["Body"].read().decode("utf-8", "replace")
    return _response(200, {
        "path": path, "content": content,
        "updatedAt": _iso(obj["LastModified"]),
    })


def put_artifact(event, path):
    _require_artifact_path(path)
    body = _body(event)
    content = body.get("content")
    if not isinstance(content, str):
        raise ApiError(400, "content must be a string")
    encoded = content.encode("utf-8")
    if len(encoded) > MAX_ARTIFACT_BYTES:
        raise ApiError(413, "artifact exceeds {} bytes".format(MAX_ARTIFACT_BYTES))
    S3.put_object(
        Bucket=BUCKET, Key=_artifact_prefix(event["_userId"]) + path,
        Body=encoded, ContentType="text/plain; charset=utf-8",
    )
    LOG.info("wrote artifact %s (%d bytes)", path, len(encoded))
    return _response(200, {"path": path, "size": len(encoded)})


def delete_artifact(event, path):
    _require_artifact_path(path)
    # S3 DELETE is idempotent by construction — no existence check needed, and
    # "already gone" is as successful an outcome as "just deleted" for a DELETE.
    S3.delete_object(Bucket=BUCKET, Key=_artifact_prefix(event["_userId"]) + path)
    LOG.info("deleted artifact %s", path)
    return _response(200, {"path": path, "deleted": True})


# --- device status (per-device supervision aggregation) ---------------------
#
# A Lambda route, not a client-side S3 list+get: presigning ListObjectsV2 would
# hand the client bucket-wide listing credentials (scoped only by a StringLike
# prefix condition — harder to reason about than a bearer-token route) and
# still cost N follow-up presigned GETs for one screen's worth of data. This
# route matches list_artifacts's shape and is callable identically by the app
# and the daemon (both already speak the plain-bearer-token relay for
# /memory and /artifacts).

DEVICE_STATUS_PREFIX = "users/{user}/fin/devices/"
MAX_DEVICE_STATUS_ITEMS = 200


def list_device_status(event):
    """GET /devices/status — every device's last-known supervision status for the
    CALLER's account, read back from users/{user}/fin/devices/*/status.json. Mirrors
    list_artifacts's paginate-and-cap S3 listing, but also GETs and parses each object
    (small, capped JSON) rather than returning bare paths: callers (memory compaction,
    a future cross-device UI) want the content."""
    user_id = event["_userId"]
    prefix = DEVICE_STATUS_PREFIX.format(user=user_id)
    keys, token = [], None
    while len(keys) < MAX_DEVICE_STATUS_ITEMS:
        kwargs = {
            "Bucket": BUCKET, "Prefix": prefix,
            "MaxKeys": min(1000, MAX_DEVICE_STATUS_ITEMS - len(keys)),
        }
        if token:
            kwargs["ContinuationToken"] = token
        page = S3.list_objects_v2(**kwargs)
        for entry in page.get("Contents", []):
            if entry["Key"].endswith("/status.json"):
                keys.append(entry["Key"])
        token = page.get("NextContinuationToken")
        if not token:
            break

    devices = []
    for key in keys:
        device_id8 = key[len(prefix):].split("/", 1)[0]  # path segment is authoritative
        try:
            raw = S3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
            status = json.loads(raw)
        except (ClientError, ValueError):
            continue
        if not isinstance(status, dict):
            continue
        status["device_id8"] = device_id8  # overwrite any self-reported mismatch
        devices.append(status)
    # Fold in the legacy flat object too: until every client writes per-device,
    # some devices' only status lives there, and omitting it would make the
    # aggregation silently incomplete exactly during the migration it exists for.
    # Its own body carries device_id8, so it self-identifies; a device that has
    # since written a per-device object wins (its entry is already in `devices`).
    seen = {d.get("device_id8") for d in devices}
    try:
        raw = S3.get_object(
            Bucket=BUCKET, Key=LEGACY_SUPERVISION_STATUS_KEY.format(user=user_id)
        )["Body"].read()
        legacy = json.loads(raw)
        if isinstance(legacy, dict) and legacy.get("device_id8") not in seen:
            legacy["legacy_flat_key"] = True
            devices.append(legacy)
    except Exception:
        # Deliberately broad: this whole block is a best-effort augmentation for
        # the migration window, and the object is ABSENT in the common case (no
        # pre-per-device client has written since the account was created). No
        # failure reading it — missing key, malformed body, transient S3 error —
        # is worth failing the caller's whole device list over.
        pass
    devices.sort(key=lambda d: d.get("updated_at") or "", reverse=True)
    return _response(200, {"generatedAt": _iso(_now()), "devices": devices})


# --- sites -------------------------------------------------------------------
#
# Phase 1a of docs/SITES.md: the registry only — who exists, who is alive, what
# each one can reach. Message dispatch, primary election and the claim protocol
# are Phase 1b and deliberately absent here; a registry that only knows
# liveness is independently useful (it is what "Fin's computers" reads) and
# independently testable, and shipping it alone changes no existing behaviour.

SITE_KINDS = ("ec2", "resident", "byo", "app")

# Default dispatch priority by kind. Higher wins the primary role in 1b: the
# always-on Mac in the study beats a cloud worker, which beats the phone in
# your pocket. Operator-overridable per site at enroll.
SITE_DEFAULT_PRIORITY = {"resident": 100, "byo": 50, "ec2": 10, "app": 1}

SITE_HEARTBEAT_SECONDS = 20
# Three missed heartbeats. Sites send DURATIONS and the Lambda stamps the
# expiry from its own clock, so a site with a skewed clock cannot forge a lease.
SITE_LEASE_SECONDS = 60

SITE_STATES = ("idle", "working", "needs-input", "task-complete", "draining")
SITE_COMMAND_KINDS = ("restart", "update", "stop", "drain")

# `enrollKey` is the operator's stable name for a physical place
# ("levis-imac/deepspacenine"), and is what makes enrollment idempotent:
# re-running the installer returns the same site with a fresh token instead of
# accumulating a new row per run.
ENROLL_KEY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$")
SITE_ID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

# Capabilities are reported verbatim by the site and echoed to the app, so they
# are capped rather than trusted: a runaway tmux inventory should fail its own
# heartbeat, not bloat every row of the caller's site list.
MAX_CAPABILITIES_BYTES = 16 * 1024
MAX_SITE_COMMANDS = 16


def _site_token_hash(token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _site_is_live(site, now=None):
    now = _now() if now is None else now
    if site.get("state") == "retired":
        return False
    lease_until = _parse_iso(site.get("leaseUntil"))
    return lease_until is not None and now < lease_until


def _public_site(site, now=None):
    """The shape the app sees. Never includes tokenSha256 — a hash is still a
    verifier, and nothing outside _authorize has any use for it."""
    now = _now() if now is None else now
    return {
        "siteId": site.get("siteId"),
        "siteId8": site.get("siteId8"),
        "agent": site.get("agent"),
        "kind": site.get("kind"),
        "displayName": site.get("displayName"),
        "priority": int(site.get("priority") or 0),
        "state": site.get("state"),
        "live": _site_is_live(site, now),
        "enrolledAt": site.get("enrolledAt"),
        "lastHeartbeatAt": site.get("lastHeartbeatAt"),
        "leaseUntil": site.get("leaseUntil"),
        "capabilities": site.get("capabilities") or {},
        "runId": site.get("runId"),
        "workerId": site.get("workerId"),
    }


def _read_site(site_id):
    if not SITE_ID_RE.match(site_id or ""):
        return None
    return SITES_TABLE.get_item(Key={"siteId": site_id}).get("Item")


def _owned_site(event, site_id):
    """A site the CALLER owns, or 404. Same reasoning as delete_worker's
    ownership check: never confirm the existence of another user's row."""
    site = _read_site(site_id)
    if not site or not site.get("userId") or site.get("userId") != event.get("_userId"):
        raise ApiError(404, "no such site")
    return site


def _site_for_enroll_key(user_id, enroll_key):
    """Idempotency lookup. A scan rather than a GSI on purpose: this table
    holds one row per physical computer a user owns — tens, not thousands —
    and it is read exactly once per install, not per heartbeat. Revisit if a
    user ever has enough bodies for this to matter."""
    items = _scan(
        table=SITES_TABLE,
        FilterExpression="userId = :user AND enrollKey = :key",
        ExpressionAttributeValues={":user": user_id, ":key": enroll_key},
    )
    return items[0] if items else None


def enroll_site(event):
    """POST /sites/enroll (operator token) — idempotent by (userId, enrollKey).

    Returns the site token in the clear exactly once per call; only its sha256
    is stored, so a lost token is re-issued by re-enrolling, never recovered."""
    body = _body(event)
    user_id = event["_userId"]

    agent = str(body.get("agent") or "").strip()
    if not AGENT_NAME.match(agent):
        raise ApiError(400, "agent must match [A-Za-z0-9][A-Za-z0-9._-]{0,62}")

    kind = str(body.get("kind") or "").strip()
    if kind not in SITE_KINDS:
        raise ApiError(400, "kind must be one of {}".format(", ".join(SITE_KINDS)))

    enroll_key = str(body.get("enrollKey") or "").strip()
    if not ENROLL_KEY_RE.match(enroll_key):
        raise ApiError(400, "enrollKey must match [A-Za-z0-9][A-Za-z0-9._/-]{0,127}")

    display_name = str(body.get("displayName") or "").strip() or kind
    if len(display_name) > 64:
        raise ApiError(400, "displayName must be 64 characters or fewer")

    priority = body.get("priority")
    if priority is None:
        priority = SITE_DEFAULT_PRIORITY[kind]
    try:
        priority = int(priority)
    except (TypeError, ValueError):
        raise ApiError(400, "priority must be an integer")
    if not 0 <= priority <= 1000:
        raise ApiError(400, "priority must be between 0 and 1000")

    now = _now()
    token = secrets.token_hex(32)
    existing = _site_for_enroll_key(user_id, enroll_key)

    if existing:
        site_id = existing["siteId"]
    else:
        # `siteId` lets the operator adopt a body that already has an identity
        # in the world — the resident iMac's device_id8 is already stamped on
        # its status objects and transcript lines, and re-minting it would
        # orphan them.
        requested = str(body.get("siteId") or "").strip().lower()
        if requested and not SITE_ID_RE.match(requested):
            raise ApiError(400, "siteId must be a lowercase uuid")
        site_id = requested or str(uuid.uuid4())
        if requested and _read_site(site_id):
            raise ApiError(409, "that siteId is already enrolled")

    site_id8 = site_id[:8]
    item = {
        "siteId": site_id,
        "siteId8": site_id8,
        "userId": user_id,
        "agent": agent,
        "kind": kind,
        "displayName": display_name,
        "priority": priority,
        "enrollKey": enroll_key,
        "tokenSha256": _site_token_hash(token),
        "enrolledAt": (existing or {}).get("enrolledAt") or _iso(now),
        "state": (existing or {}).get("state") or "idle",
        "capabilities": (existing or {}).get("capabilities") or {},
        "commands": (existing or {}).get("commands") or [],
        "rev": int((existing or {}).get("rev") or 0),
    }
    for carried in ("lastHeartbeatAt", "leaseUntil", "runId", "transcriptKey", "workerId"):
        if (existing or {}).get(carried):
            item[carried] = existing[carried]
    SITES_TABLE.put_item(Item=item)

    return _response(200, {
        "siteId": site_id,
        "siteId8": site_id8,
        "siteToken": token,
        "heartbeatSeconds": SITE_HEARTBEAT_SECONDS,
        "reEnrolled": bool(existing),
    })


def list_sites(event):
    """GET /sites[?agent=] — the caller's own sites. Operator token only: a
    site token is scoped to its own row, and one body has no business
    enumerating its siblings."""
    user_id = event["_userId"]
    agent = str(((event.get("queryStringParameters") or {}).get("agent") or "")).strip()
    expression = "userId = :user"
    values = {":user": user_id}
    kwargs = {}
    if agent:
        # `agent` is a DynamoDB reserved word; it must be aliased in every expression.
        expression += " AND #agent = :agent"
        values[":agent"] = agent
        kwargs["ExpressionAttributeNames"] = {"#agent": "agent"}
    now = _now()
    sites = [
        _public_site(s, now)
        for s in _scan(table=SITES_TABLE, FilterExpression=expression, ExpressionAttributeValues=values, **kwargs)
    ]
    sites.sort(key=lambda s: (-int(s.get("priority") or 0), s.get("displayName") or ""))
    return _response(200, {"generatedAt": _iso(now), "sites": sites})


def _site_refresh_urls(user_id, agent, site_id8):
    """The presigned set a daemon needs to keep working, re-signed on the
    heartbeat. Deliberately a small explicit list rather than a call into
    `presign`: that route's job is to answer a client's arbitrary `kinds`
    request, this one's is to hand a site exactly what its run loop reads and
    writes, and collapsing them would couple two different contracts."""
    slug = _key_slug(agent)
    inbox_key = INBOX_KEY.format(user=user_id, agent=slug)
    return {
        "supervisionDirectiveGet": _presign(
            "get_object", SUPERVISION_DIRECTIVE_KEY.format(user=user_id)
        ),
        "supervisionStatusPut": _presign(
            "put_object", DEVICE_STATUS_KEY.format(user=user_id, device=site_id8)
        ),
        "inboxGet": _presign("get_object", inbox_key),
        "inboxPut": _presign("put_object", inbox_key),
        "transcriptPut": _presign("put_object", TRANSCRIPT_KEY.format(user=user_id, agent=slug)),
    }


def site_heartbeat(event, site_id):
    """POST /sites/{siteId}/heartbeat — renew the lease, record what this body
    can reach, drain its queued commands, and re-sign its URLs before they
    lapse.

    Runs from a task INDEPENDENT of the daemon's turn loop, which is the whole
    reason it exists: today's status uplink only runs in the wait between
    turns, and a multi-tool turn on a local 12B model takes minutes — so a site
    that is working hardest is exactly the one that looks dead to every lease.
    `state: "working"` is therefore online, not busy-and-unreachable."""
    site = _owned_site(event, site_id)
    body = _body(event)

    state = str(body.get("state") or "idle").strip()
    if state not in SITE_STATES:
        raise ApiError(400, "state must be one of {}".format(", ".join(SITE_STATES)))

    capabilities = body.get("capabilities")
    if capabilities is None:
        capabilities = site.get("capabilities") or {}
    if not isinstance(capabilities, dict):
        raise ApiError(400, "capabilities must be an object")
    if len(json.dumps(capabilities, default=_json_default)) > MAX_CAPABILITIES_BYTES:
        raise ApiError(413, "capabilities exceed {} bytes".format(MAX_CAPABILITIES_BYTES))

    now = _now()
    lease_until = now + timedelta(seconds=SITE_LEASE_SECONDS)
    commands = list(site.get("commands") or [])

    updated = dict(site)
    updated.update({
        "state": state,
        "capabilities": capabilities,
        "lastHeartbeatAt": _iso(now),
        "leaseUntil": _iso(lease_until),
        "commands": [],
        "rev": int(site.get("rev") or 0) + 1,
    })
    for field in ("runId", "transcriptKey"):
        value = body.get(field)
        if isinstance(value, str) and value:
            updated[field] = value

    try:
        # Conditional on `rev`: the drain above is a read-modify-write, and an
        # operator queuing a command between the read and the write would
        # otherwise have it silently dropped. A 409 here means exactly that
        # happened; the site retries on its next beat 20 s later, so the
        # command is delayed, never lost.
        SITES_TABLE.put_item(
            Item=updated,
            ConditionExpression="rev = :rev",
            ExpressionAttributeValues={":rev": int(site.get("rev") or 0)},
        )
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
            raise ApiError(409, "site row changed underneath this heartbeat; retry")
        raise

    response = {
        "leaseUntil": _iso(lease_until),
        "heartbeatSeconds": SITE_HEARTBEAT_SECONDS,
        "commands": commands,
    }
    response.update(_heartbeat_dispatch(updated, body, now))

    # Re-sign before the daemon's copies lapse, not after: URLs signed with the
    # Lambda's temporary credentials die with those credentials regardless of
    # their stated expiry, so "refresh when the site says it is within 20
    # minutes of expiry" is the floor, and a site that reports nothing gets a
    # fresh set.
    expires_at = _parse_iso(body.get("urlsExpireAt"))
    if expires_at is None or expires_at - now < timedelta(minutes=20):
        response["urls"] = _site_refresh_urls(site["userId"], site["agent"], site["siteId8"])
        response["urlsExpireAt"] = _iso(now + timedelta(seconds=PRESIGN_TTL_SECONDS))

    return _response(200, response)


def queue_site_command(event, site_id):
    """POST /sites/{siteId}/commands (operator token) — {kind, args?}. Delivered
    on the site's next heartbeat; there is no inbound path to a site by design,
    so a box behind a tailnet is as reachable as an EC2 instance."""
    site = _owned_site(event, site_id)
    body = _body(event)
    kind = str(body.get("kind") or "").strip()
    if kind not in SITE_COMMAND_KINDS:
        raise ApiError(400, "kind must be one of {}".format(", ".join(SITE_COMMAND_KINDS)))
    args = body.get("args") or {}
    if not isinstance(args, dict):
        raise ApiError(400, "args must be an object")

    pending = list(site.get("commands") or [])
    if len(pending) >= MAX_SITE_COMMANDS:
        # A site that is not draining its queue is not listening; piling more on
        # helps nobody and is how a row grows without bound.
        raise ApiError(409, "this site has {} undelivered commands".format(len(pending)))
    command = {"id": "c-" + str(uuid.uuid4()), "kind": kind, "args": args, "queuedAt": _iso(_now())}
    pending.append(command)

    try:
        SITES_TABLE.update_item(
            Key={"siteId": site_id},
            UpdateExpression="SET commands = :c, rev = :next",
            ConditionExpression="rev = :rev",
            ExpressionAttributeValues={
                ":c": pending,
                ":rev": int(site.get("rev") or 0),
                ":next": int(site.get("rev") or 0) + 1,
            },
        )
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
            raise ApiError(409, "site row changed underneath this write; retry")
        raise
    return _response(200, {"command": command})


def delete_site(event, site_id):
    """DELETE /sites/{siteId} — retire it. The row is kept (it is the only
    record of what that body was, and the sweep still reads it) but its token
    hash is destroyed, so a leaked token dies with the same call."""
    site = _owned_site(event, site_id)
    SITES_TABLE.update_item(
        Key={"siteId": site_id},
        UpdateExpression=(
            "SET #state = :retired, retiredAt = :now, rev = :next REMOVE tokenSha256, leaseUntil"
        ),
        ExpressionAttributeNames={"#state": "state"},
        ExpressionAttributeValues={
            ":retired": "retired",
            ":now": _iso(_now()),
            ":next": int(site.get("rev") or 0) + 1,
        },
    )
    return _response(200, {"siteId": site_id, "state": "retired"})


# --- messages, claims, and primary election ----------------------------------
#
# Phase 1b of docs/SITES.md §3.4 and §6. A message is applied by AT MOST ONE
# body, and the thing that decides which one is a DynamoDB conditional write on
# the message row — never "whoever polled first". Roles (primary/standby) only
# ROUTE; claims EXCLUDE.


MESSAGE_ID_RE = re.compile(r"^m-[A-Za-z0-9][A-Za-z0-9._-]{7,79}$")
MESSAGE_SOURCES = ("app", "voice", "mac-terminal", "legacy", "supervisor")
MESSAGE_STATES = ("queued", "claimed", "applied", "answered", "expired")
MAX_MESSAGE_CHARS = 8000
MAX_REPLY_PREVIEW_CHARS = 500
# A claim lease outlives a whole heartbeat gap several times over; a site that
# holds a message renews it on every beat, and a site that dies stops renewing,
# so the row is re-offered within this long. 120 s is the design's number.
MESSAGE_LEASE_SECONDS_DEFAULT = 120
MESSAGE_LEASE_SECONDS_MAX = 600
# Primary role lease: one heartbeat interval is 20 s, so a silent primary is
# replaced after three missed beats — the same arithmetic as the site lease.
PRIMARY_LEASE_SECONDS = SITE_LEASE_SECONDS
# Answered/expired rows linger this long so GET /messages/{id} can still answer
# a late poll, then DynamoDB TTL reaps them.
MESSAGE_RETENTION_DAYS = 14
MESSAGES_PER_HEARTBEAT = 10
MAX_LISTED_MESSAGES = 50


def _agent_key(user_id, agent):
    """fin-agents is keyed per (user, agent): an agent name is only unique
    within one user's account, never globally."""
    return "{}/{}".format(user_id, _key_slug(agent))


def _read_agent_row(user_id, agent):
    return AGENTS_TABLE.get_item(Key={"agentKey": _agent_key(user_id, agent)}).get("Item") or {}


def _elect_primary(user_id, agent, site, now):
    """§6.1: one conditional update per heartbeat. The iMac (100) preempts a
    cloud worker (10) on its first beat; a silent primary is replaced after its
    lease lapses; the loser reads back `standby`. Returns "primary" or "standby"."""
    until = now + timedelta(seconds=PRIMARY_LEASE_SECONDS)
    try:
        AGENTS_TABLE.update_item(
            Key={"agentKey": _agent_key(user_id, agent)},
            UpdateExpression=(
                "SET userId = :user, #agent = :agent, primarySiteId = :me, "
                "primaryPriority = :p, primaryLeaseUntil = :until"
            ),
            ConditionExpression=(
                "attribute_not_exists(primarySiteId) OR primarySiteId = :me "
                "OR primaryLeaseUntil < :now OR primaryPriority < :p"
            ),
            ExpressionAttributeNames={"#agent": "agent"},
            ExpressionAttributeValues={
                ":user": user_id,
                ":agent": agent,
                ":me": site["siteId"],
                ":p": int(site.get("priority") or 0),
                ":until": _iso(until),
                ":now": _iso(now),
            },
        )
        return "primary"
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
            return "standby"
        raise


def _primary_is_live(agent_row, now):
    lease = _parse_iso(agent_row.get("primaryLeaseUntil"))
    return bool(agent_row.get("primarySiteId")) and lease is not None and now < lease


def _live_sites(user_id, agent, now):
    rows = _scan(
        table=SITES_TABLE,
        FilterExpression="userId = :user AND #agent = :agent",
        ExpressionAttributeNames={"#agent": "agent"},
        ExpressionAttributeValues={":user": user_id, ":agent": agent},
    )
    return [s for s in rows if _site_is_live(s, now)]


def _word_mentioned(word, text):
    """Whole-word, case-insensitive — the same rule as the app's
    SessionRouter.wordMentioned, so a message routes the same way whether the
    app or the control plane decides."""
    word = (word or "").strip()
    if not word:
        return False
    return re.search(r"(?<![A-Za-z0-9_])" + re.escape(word) + r"(?![A-Za-z0-9_])", text, re.IGNORECASE) is not None


def _pin_for(text, context, live_sites):
    """§3.4, as a pure function. Returns (pinSiteId, routedBy, candidates):
    - `siteHint` naming a live site pins to it ("hint");
    - otherwise the message text plus the sender's active session names are
      matched against every live site's tmux sessions and task vocabulary —
      exactly one site → pin ("context"); several → no pin and "clarify" with
      the candidates' display names; none → no pin, routed by primary later."""
    context = context if isinstance(context, dict) else {}
    hint = str(context.get("siteHint") or "").strip().lower()
    if hint:
        for site in live_sites:
            if hint in (site.get("siteId"), site.get("siteId8")):
                return site["siteId"], "hint", []

    haystack = text or ""
    names = context.get("activeSessionNames")
    if isinstance(names, list):
        haystack += "\n" + " ".join(str(n) for n in names if isinstance(n, str))

    matched = []
    for site in live_sites:
        sessions = ((site.get("capabilities") or {}).get("tmux_sessions") or [])
        words = []
        for entry in sessions:
            if not isinstance(entry, dict):
                continue
            words.append(str(entry.get("session") or ""))
            words.extend(str(t) for t in (entry.get("tasks") or []) if isinstance(t, str))
        if any(_word_mentioned(w, haystack) for w in words):
            matched.append(site)
    if len(matched) == 1:
        return matched[0]["siteId"], "context", []
    if len(matched) > 1:
        return None, "clarify", [s.get("displayName") for s in matched]
    return None, None, []


def _eligible(row, site_id, is_primary, primary_live, target_live, now):
    """§6.2 for one row. `target_live` is a callable siteId -> bool so the pure
    rule can be tested without a table."""
    state = row.get("state")
    lease = _parse_iso(row.get("leaseUntil"))
    if state == "claimed":
        if lease is not None and now < lease:
            return False
    elif state != "queued":
        return False
    pin = row.get("pinSiteId")
    if pin:
        return pin == site_id
    target = row.get("targetSiteId")
    if target == site_id:
        return True
    if target and target_live(target):
        return False
    if is_primary:
        return True
    return not primary_live


def _open_messages(user_id, agent):
    return _scan(
        table=MESSAGES_TABLE,
        FilterExpression="userId = :user AND #agent = :agent AND #state IN (:queued, :claimed)",
        ExpressionAttributeNames={"#agent": "agent", "#state": "state"},
        ExpressionAttributeValues={
            ":user": user_id, ":agent": agent, ":queued": "queued", ":claimed": "claimed",
        },
    )


def _public_message(row):
    return {
        "messageId": row.get("messageId"),
        "agent": row.get("agent"),
        "text": row.get("text"),
        "source": row.get("source"),
        "createdAt": row.get("createdAt"),
        "state": row.get("state"),
        "routedBy": row.get("routedBy"),
        "pinSiteId": row.get("pinSiteId"),
        "targetSiteId": row.get("targetSiteId"),
        "targetSiteName": row.get("targetSiteName"),
        "clarifyCandidates": row.get("clarifyCandidates") or [],
        "claimedBy": row.get("claimedBy"),
        "claimedAt": row.get("claimedAt"),
        "appliedAt": row.get("appliedAt"),
        "appliedRunId": row.get("appliedRunId"),
        "answeredAt": row.get("answeredAt"),
        "replyPreview": row.get("replyPreview"),
    }


def _owned_message(event, message_id):
    if not MESSAGE_ID_RE.match(message_id or ""):
        raise ApiError(404, "no such message")
    row = MESSAGES_TABLE.get_item(Key={"messageId": message_id}).get("Item")
    if not row or not row.get("userId") or row.get("userId") != event.get("_userId"):
        raise ApiError(404, "no such message")
    return row


def send_message(event):
    """POST /messages — {agent, text, messageId?, source?, context?}. Idempotent
    on messageId: a retry with the same id is a no-op that returns the row as
    it stands, so a flaky network can never double-send."""
    body = _body(event)
    user_id = event["_userId"]

    agent = str(body.get("agent") or "").strip()
    if not AGENT_NAME.match(agent):
        raise ApiError(400, "agent must match [A-Za-z0-9][A-Za-z0-9._-]{0,62}")
    text = body.get("text")
    if not isinstance(text, str) or not text.strip():
        raise ApiError(400, "text must be a non-empty string")
    if len(text) > MAX_MESSAGE_CHARS:
        raise ApiError(413, "text exceeds {} characters".format(MAX_MESSAGE_CHARS))
    source = str(body.get("source") or "app").strip()
    if source not in MESSAGE_SOURCES:
        raise ApiError(400, "source must be one of {}".format(", ".join(MESSAGE_SOURCES)))
    message_id = str(body.get("messageId") or "").strip()
    if message_id and not MESSAGE_ID_RE.match(message_id):
        raise ApiError(400, "messageId must look like m-<uuid>")
    if not message_id:
        message_id = "m-" + str(uuid.uuid4())
    context = body.get("context") if isinstance(body.get("context"), dict) else {}

    now = _now()
    live = _live_sites(user_id, agent, now)
    pin, routed_by, candidates = _pin_for(text, context, live)
    target = None
    if pin is None and routed_by != "clarify":
        agent_row = _read_agent_row(user_id, agent)
        if _primary_is_live(agent_row, now):
            target = agent_row.get("primarySiteId")
            routed_by = "primary"
    by_id = {s["siteId"]: s for s in live}
    target_name = (by_id.get(pin or target) or {}).get("displayName")

    row = {
        "messageId": message_id,
        "userId": user_id,
        "agent": agent,
        "text": text,
        "source": source,
        "createdAt": _iso(now),
        "state": "queued",
        "context": context,
        "routedBy": routed_by,
        "clarifyCandidates": candidates,
    }
    if pin:
        row["pinSiteId"] = pin
    if target:
        row["targetSiteId"] = target
    if target_name:
        row["targetSiteName"] = target_name
    author = str(context.get("device_id8") or "").strip().lower()
    if DEVICE_ID_RE.match(author):
        row["authorSiteId8"] = author

    try:
        MESSAGES_TABLE.put_item(Item=row, ConditionExpression="attribute_not_exists(messageId)")
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") != "ConditionalCheckFailedException":
            raise
        existing = _owned_message(event, message_id)
        return _response(200, dict(_public_message(existing), duplicate=True))
    return _response(200, _public_message(row))


def get_message(event, message_id):
    return _response(200, _public_message(_owned_message(event, message_id)))


def list_messages(event):
    """GET /messages?agent= — the caller's most recent rows for one agent,
    newest first, for the console's pending/queued/answered rendering."""
    user_id = event["_userId"]
    agent = str(((event.get("queryStringParameters") or {}).get("agent") or "")).strip()
    if not AGENT_NAME.match(agent):
        raise ApiError(400, "agent query parameter is required")
    rows = _scan(
        table=MESSAGES_TABLE,
        FilterExpression="userId = :user AND #agent = :agent",
        ExpressionAttributeNames={"#agent": "agent"},
        ExpressionAttributeValues={":user": user_id, ":agent": agent},
    )
    rows.sort(key=lambda r: r.get("createdAt") or "", reverse=True)
    return _response(200, {"agent": agent, "messages": [_public_message(r) for r in rows[:MAX_LISTED_MESSAGES]]})


def _acting_site(event):
    """The body performing a claim/ack/register: the authenticated site, or —
    for an operator/session token, which the app uses when it acts as a site
    itself — the row named by `siteId` in the body. Either way the site must
    belong to the caller."""
    site_id = event.get("_siteId")
    if not site_id:
        site_id = str(_body(event).get("siteId") or "").strip().lower()
        if not site_id:
            raise ApiError(400, "siteId is required when not authenticated as a site")
    return _owned_site(event, site_id)


def _same_agent(site, row):
    return _key_slug(site.get("agent") or "") == _key_slug(row.get("agent") or "")


def claim_message(event, message_id):
    """§6.3 step 3. Exactly one body wins; the condition is the whole story."""
    site = _acting_site(event)
    row = _owned_message(event, message_id)
    if not _same_agent(site, row):
        raise ApiError(404, "no such message")
    body = _body(event)
    try:
        lease_seconds = int(body.get("leaseSeconds") or MESSAGE_LEASE_SECONDS_DEFAULT)
    except (TypeError, ValueError):
        raise ApiError(400, "leaseSeconds must be an integer")
    lease_seconds = max(10, min(lease_seconds, MESSAGE_LEASE_SECONDS_MAX))
    now = _now()
    try:
        MESSAGES_TABLE.update_item(
            Key={"messageId": message_id},
            UpdateExpression="SET claimedBy = :me, claimedAt = :now, leaseUntil = :until, #state = :claimed",
            ConditionExpression=(
                "attribute_not_exists(claimedBy) OR claimedBy = :me "
                "OR (leaseUntil < :now AND #state IN (:queued, :claimed))"
            ),
            ExpressionAttributeNames={"#state": "state"},
            ExpressionAttributeValues={
                ":me": site["siteId"],
                ":now": _iso(now),
                ":until": _iso(now + timedelta(seconds=lease_seconds)),
                ":claimed": "claimed",
                ":queued": "queued",
            },
        )
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
            return _response(409, {"granted": False, "messageId": message_id})
        raise
    return _response(200, {
        "granted": True,
        "messageId": message_id,
        "leaseUntil": _iso(now + timedelta(seconds=lease_seconds)),
        "text": row.get("text"),
        "source": row.get("source"),
        "createdAt": row.get("createdAt"),
    })


def ack_message(event, message_id):
    """§6.3 steps 5–6: {state: applied|answered, runId?, replyPreview?}. Only
    the claimant may ack, and only forward (queued/claimed → applied →
    answered) — a late duplicate ack is a 409, not a rewind."""
    site = _acting_site(event)
    row = _owned_message(event, message_id)
    if not _same_agent(site, row):
        raise ApiError(404, "no such message")
    body = _body(event)
    state = str(body.get("state") or "").strip()
    if state not in ("applied", "answered"):
        raise ApiError(400, "state must be applied or answered")
    now = _now()
    names = {"#state": "state"}
    values = {":me": site["siteId"], ":now": _iso(now)}
    if state == "applied":
        update = "SET #state = :applied, appliedAt = :now, appliedBy = :me"
        values[":applied"] = "applied"
        values[":queued"] = "queued"
        values[":claimed"] = "claimed"
        condition = "claimedBy = :me AND #state IN (:queued, :claimed)"
        run_id = body.get("runId")
        if isinstance(run_id, str) and run_id:
            update += ", appliedRunId = :run"
            values[":run"] = run_id
    else:
        update = "SET #state = :answered, answeredAt = :now, #ttl = :ttl"
        names["#ttl"] = "ttl"
        values[":answered"] = "answered"
        values[":applied"] = "applied"
        values[":ttl"] = int((now + timedelta(days=MESSAGE_RETENTION_DAYS)).timestamp())
        condition = "claimedBy = :me AND #state = :applied"
        preview = body.get("replyPreview")
        if isinstance(preview, str) and preview.strip():
            update += ", replyPreview = :preview"
            values[":preview"] = preview.strip()[:MAX_REPLY_PREVIEW_CHARS]
    try:
        MESSAGES_TABLE.update_item(
            Key={"messageId": message_id},
            UpdateExpression=update,
            ConditionExpression=condition,
            ExpressionAttributeNames=names,
            ExpressionAttributeValues=values,
        )
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
            raise ApiError(409, "not the claimant, or the message is already past that state")
        raise
    if state == "applied" and row.get("source") == "legacy":
        _trim_legacy_inbox(row["userId"], row["agent"], message_id)
    return _response(200, {"messageId": message_id, "state": state})


def register_message(event, message_id):
    """§6.5: the primary lifts an entry out of the legacy inbox document into a
    real row so even a preemption race on that document is settled by the
    claim. 200 whether this call created the row or it already existed."""
    site = _acting_site(event)
    if not MESSAGE_ID_RE.match(message_id or ""):
        raise ApiError(400, "messageId must look like m-<uuid>")
    body = _body(event)
    text = body.get("text")
    if not isinstance(text, str) or not text.strip():
        raise ApiError(400, "text must be a non-empty string")
    now = _now()
    row = {
        "messageId": message_id,
        "userId": site["userId"],
        "agent": site["agent"],
        "text": text[:MAX_MESSAGE_CHARS],
        "source": "legacy",
        "createdAt": _iso(now),
        "state": "queued",
        "context": {},
        "routedBy": "legacy",
        "pinSiteId": site["siteId"],
        "clarifyCandidates": [],
    }
    try:
        MESSAGES_TABLE.put_item(Item=row, ConditionExpression="attribute_not_exists(messageId)")
        created = True
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") != "ConditionalCheckFailedException":
            raise
        created = False
    return _response(200, {"messageId": message_id, "created": created})


def _trim_legacy_inbox(user_id, agent, message_id):
    """Remove one applied id from fin/inbox/{agent}.json with If-Match, one
    retry on a lost race. Best-effort: an old build's concurrent GET-merge-PUT
    can at worst resurrect an already-applied id, which every consumer's
    ledger ignores — so a failure here is logged, never surfaced."""
    key = INBOX_KEY.format(user=user_id, agent=_key_slug(agent))
    for _attempt in range(2):
        try:
            obj = S3.get_object(Bucket=BUCKET, Key=key)
            document = json.loads(obj["Body"].read())
            etag = obj.get("ETag")
        except (ClientError, ValueError):
            return
        directives = document.get("directives") if isinstance(document, dict) else None
        if not isinstance(directives, list):
            return
        kept = [d for d in directives if not (isinstance(d, dict) and d.get("id") == message_id)]
        if len(kept) == len(directives):
            return
        document["directives"] = kept
        try:
            S3.put_object(
                Bucket=BUCKET, Key=key, Body=json.dumps(document).encode("utf-8"),
                ContentType="application/json", IfMatch=etag,
            )
            return
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") in ("PreconditionFailed", "412"):
                continue
            LOG.warning("legacy inbox trim failed for %s: %s", agent, _scrub(exc))
            return


def _heartbeat_dispatch(site, body, now):
    """The message half of a heartbeat: election, held-lease renewal, unacked
    crash recovery, and the eligible rows to offer. Returns the fields to
    merge into the heartbeat response."""
    user_id, agent = site["userId"], site["agent"]
    wants_primary = bool(body.get("wantsPrimary", True))
    role = _elect_primary(user_id, agent, site, now) if wants_primary else "standby"
    agent_row = _read_agent_row(user_id, agent)
    is_primary = agent_row.get("primarySiteId") == site["siteId"] and _primary_is_live(agent_row, now)
    primary_live = _primary_is_live(agent_row, now)

    held = [m for m in (body.get("held") or []) if isinstance(m, str) and MESSAGE_ID_RE.match(m)]
    unacked = [m for m in (body.get("unacked") or []) if isinstance(m, str) and MESSAGE_ID_RE.match(m)]

    renewed_until = _iso(now + timedelta(seconds=MESSAGE_LEASE_SECONDS_DEFAULT))
    for message_id in held[:MESSAGES_PER_HEARTBEAT * 2]:
        try:
            MESSAGES_TABLE.update_item(
                Key={"messageId": message_id},
                UpdateExpression="SET leaseUntil = :until",
                ConditionExpression="claimedBy = :me AND #state = :claimed",
                ExpressionAttributeNames={"#state": "state"},
                ExpressionAttributeValues={":me": site["siteId"], ":until": renewed_until, ":claimed": "claimed"},
            )
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") != "ConditionalCheckFailedException":
                raise
    # §6.4 "site dies after submit, before ack": the id is in the daemon's
    # `unacked` ledger; acking it here under claimedBy=me means the row leaves
    # `queued` before anyone else can be offered it.
    for message_id in unacked[:MESSAGES_PER_HEARTBEAT * 2]:
        try:
            MESSAGES_TABLE.update_item(
                Key={"messageId": message_id},
                UpdateExpression="SET #state = :applied, appliedAt = :now, appliedBy = :me",
                ConditionExpression="claimedBy = :me AND #state IN (:queued, :claimed)",
                ExpressionAttributeNames={"#state": "state"},
                ExpressionAttributeValues={
                    ":me": site["siteId"], ":now": _iso(now),
                    ":applied": "applied", ":queued": "queued", ":claimed": "claimed",
                },
            )
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") != "ConditionalCheckFailedException":
                raise

    live_cache = {}

    def target_live(site_id):
        if site_id not in live_cache:
            row = _read_site(site_id)
            live_cache[site_id] = bool(row) and _site_is_live(row, now)
        return live_cache[site_id]

    offers = []
    for row in sorted(_open_messages(user_id, agent), key=lambda r: r.get("createdAt") or ""):
        if row.get("messageId") in held:
            continue
        if _eligible(row, site["siteId"], is_primary, primary_live, target_live, now):
            offers.append({
                "id": row["messageId"],
                "text": row.get("text"),
                "source": row.get("source"),
                "createdAt": row.get("createdAt"),
                "pinSiteId": row.get("pinSiteId"),
            })
        if len(offers) >= MESSAGES_PER_HEARTBEAT:
            break

    result = {"role": role, "messages": offers}
    if is_primary:
        result["legacyInboxGet"] = _presign("get_object", INBOX_KEY.format(user=user_id, agent=_key_slug(agent)))
    return result


def _mark_stale_sites(now):
    """Sweep half for sites: a site silent for three leases is `stale` (never
    terminated — a resident Mac is not ours to kill). Returns the ids marked."""
    cutoff = now - timedelta(seconds=3 * SITE_LEASE_SECONDS)
    marked = []
    for site in _scan(table=SITES_TABLE):
        if site.get("state") in ("stale", "retired"):
            continue
        lease = _parse_iso(site.get("leaseUntil"))
        if lease is not None and lease > cutoff:
            continue
        if lease is None and site.get("lastHeartbeatAt") is None:
            continue  # enrolled, never beat: not stale, just not started yet
        try:
            SITES_TABLE.update_item(
                Key={"siteId": site["siteId"]},
                UpdateExpression="SET #state = :stale, rev = :next",
                ConditionExpression="rev = :rev",
                ExpressionAttributeNames={"#state": "state"},
                ExpressionAttributeValues={
                    ":stale": "stale", ":rev": int(site.get("rev") or 0), ":next": int(site.get("rev") or 0) + 1,
                },
            )
            marked.append(site["siteId"])
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") != "ConditionalCheckFailedException":
                raise
            continue
        # A resident/BYO Mac going silent is news the owner wants once, at the
        # transition — never per tick, and never for a cloud worker (the EC2
        # sweep owns those) or a phone that simply went to sleep.
        if site.get("kind") in ("resident", "byo") and site.get("userId"):
            _notify_lost_contact(site)
    return marked


def _notify_lost_contact(site):
    synthetic_event = {"_userId": site["userId"], "body": json.dumps({
        "title": "Fin lost contact with {}".format(site.get("displayName") or "a computer"),
        "body": "No heartbeat for {} minutes. If the Mac is awake, check fin-agentd there.".format(
            3 * SITE_LEASE_SECONDS // 60),
        "agent": site.get("agent") or "Fin",
    })}
    try:
        notify(synthetic_event)
    except Exception:  # noqa: BLE001 - one push failure must never abort the sweep
        LOG.exception("stale-site notify failed for %s", site.get("siteId"))


# --- Phase 2/3: enroll tokens, goals ledger, binary update, device-site wake --

ENROLL_TOKEN_TTL_SECONDS = 15 * 60
# Where the build host publishes the macOS daemon for the `update` command, and
# the sidecar the daemon verifies it against before the atomic rename.
MACOS_BINARY_KEY = "fin/agentd/fin-agentd-macos-arm64"
MACOS_BINARY_SHA256_KEY = MACOS_BINARY_KEY + ".sha256"
GOALS_KEY = "users/{user}/fin/agents/{agent}/goals-ledger.v{version}.json"
MAX_GOALS_BYTES = 256 * 1024
# A queued message nobody has claimed for this long, with no live site for the
# agent, wakes a cloud body. Same grace the inbox-based wake used.
DEVICE_WAKE_GRACE_MINUTES = int(os.environ.get("FIN_CP_WAKE_GRACE_MINUTES", "3"))


def _enroll_token_hash(token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def mint_enroll_token(event):
    """POST /sites/enroll-tokens (operator/session) — {agent, kind?, displayName?}
    → {enrollToken, expiresAt}. One-time, 15 minutes: the installer on a new
    Mac redeems it via POST /sites/enroll and never sees an operator bearer."""
    body = _body(event)
    agent = str(body.get("agent") or "").strip()
    if not AGENT_NAME.match(agent):
        raise ApiError(400, "agent must match [A-Za-z0-9][A-Za-z0-9._-]{0,62}")
    kind = str(body.get("kind") or "resident").strip()
    if kind not in SITE_KINDS:
        raise ApiError(400, "kind must be one of {}".format(", ".join(SITE_KINDS)))
    display_name = str(body.get("displayName") or "").strip()[:64]
    now = _now()
    token = secrets.token_hex(24)
    expires = now + timedelta(seconds=ENROLL_TOKEN_TTL_SECONDS)
    ENROLL_TOKENS_TABLE.put_item(Item={
        "tokenSha256": _enroll_token_hash(token),
        "userId": event["_userId"],
        "agent": agent,
        "kind": kind,
        "displayName": display_name,
        "createdAt": _iso(now),
        "expiresAt": _iso(expires),
        "ttl": int(expires.timestamp()),
    })
    return _response(200, {"enrollToken": token, "expiresAt": _iso(expires), "agent": agent, "kind": kind})


def enroll_with_token(event):
    """POST /sites/enroll with {enrollToken, …} and NO bearer: the token is the
    authorization. Consumed on success (a conditional delete is the one-time
    guarantee); expired or unknown → 401, same as any bad credential."""
    body = _body(event)
    token = str(body.get("enrollToken") or "").strip()
    if not token:
        raise ApiError(401, "unauthorized")
    key = {"tokenSha256": _enroll_token_hash(token)}
    row = ENROLL_TOKENS_TABLE.get_item(Key=key).get("Item")
    expires = _parse_iso((row or {}).get("expiresAt"))
    if not row or expires is None or _now() >= expires:
        raise ApiError(401, "unauthorized")
    try:
        ENROLL_TOKENS_TABLE.delete_item(Key=key, ConditionExpression="attribute_exists(tokenSha256)")
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
            raise ApiError(401, "unauthorized")
        raise
    event["_userId"] = row["userId"]
    filled = dict(body)
    filled.setdefault("agent", row["agent"])
    filled.setdefault("kind", row.get("kind") or "resident")
    if row.get("displayName") and not filled.get("displayName"):
        filled["displayName"] = row["displayName"]
    event["body"] = json.dumps(filled)
    event.pop("isBase64Encoded", None)
    return enroll_site(event)


# --- goals ledger ---------------------------------------------------------------


def _goals_agent_check(event, agent):
    """A site token may only sync its own agent's ledger."""
    if event.get("_siteId"):
        site = _read_site(event["_siteId"]) or {}
        if _key_slug(site.get("agent") or "") != _key_slug(agent):
            raise ApiError(404, "no such agent")


def get_goals(event, agent):
    """GET /agents/{agent}/goals → {version, document|null}."""
    if not AGENT_NAME.match(agent or ""):
        raise ApiError(400, "agent must match [A-Za-z0-9][A-Za-z0-9._-]{0,62}")
    _goals_agent_check(event, agent)
    user_id = event["_userId"]
    row = _read_agent_row(user_id, agent)
    version = int(row.get("goalsVersion") or 0)
    document = None
    if version > 0:
        key = GOALS_KEY.format(user=user_id, agent=_key_slug(agent), version=version)
        try:
            document = json.loads(S3.get_object(Bucket=BUCKET, Key=key)["Body"].read())
        except (ClientError, ValueError):
            document = None
    return _response(200, {"version": version, "document": document, "updatedBy": row.get("goalsUpdatedBy")})


def put_goals(event, agent):
    """PUT /agents/{agent}/goals with If-Match: <version> and {document}.
    The version bump is a conditional update on fin-agents FIRST; the loser
    gets 412 with the current version and document to three-way merge against.
    Versioned S3 keys sidestep the 400 KB item cap and make every version
    addressable."""
    if not AGENT_NAME.match(agent or ""):
        raise ApiError(400, "agent must match [A-Za-z0-9][A-Za-z0-9._-]{0,62}")
    _goals_agent_check(event, agent)
    body = _body(event)
    document = body.get("document")
    if not isinstance(document, dict):
        raise ApiError(400, "document must be a JSON object")
    encoded = json.dumps(document, default=_json_default).encode("utf-8")
    if len(encoded) > MAX_GOALS_BYTES:
        raise ApiError(413, "goals ledger exceeds {} bytes".format(MAX_GOALS_BYTES))
    expected_raw = _header(event, "if-match").strip().strip('"')
    try:
        expected = int(expected_raw)
    except ValueError:
        raise ApiError(428, "If-Match: <version> is required")

    user_id = event["_userId"]
    slug = _key_slug(agent)
    updated_by = event.get("_siteId") or "operator"
    next_version = expected + 1
    try:
        AGENTS_TABLE.update_item(
            Key={"agentKey": _agent_key(user_id, agent)},
            UpdateExpression="SET userId = :user, #agent = :agent, goalsVersion = :next, goalsUpdatedBy = :by, goalsUpdatedAt = :now",
            ConditionExpression="attribute_not_exists(goalsVersion) OR goalsVersion = :expected",
            ExpressionAttributeNames={"#agent": "agent"},
            ExpressionAttributeValues={
                ":user": user_id, ":agent": agent, ":next": next_version, ":by": updated_by,
                ":now": _iso(_now()), ":expected": expected,
            },
        )
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") != "ConditionalCheckFailedException":
            raise
        current = json.loads(get_goals(event, agent)["body"])
        return _response(412, {"error": "version conflict", "version": current["version"], "document": current["document"]})
    if expected == 0 and next_version == 1:
        pass  # first write: attribute_not_exists branch
    S3.put_object(
        Bucket=BUCKET, Key=GOALS_KEY.format(user=user_id, agent=slug, version=next_version),
        Body=encoded, ContentType="application/json",
    )
    return _response(200, {"version": next_version})


# --- wake on fin-messages (device sites) ---------------------------------------


def _queued_message_candidates(now):
    """(userId, agent, oldest unclaimed createdAt) for every agent with a queued
    row nobody has claimed — the successor to the inbox-object scan, read from
    the table the app now writes to."""
    oldest = {}
    for row in _scan(
        table=MESSAGES_TABLE,
        FilterExpression="#state = :queued",
        ExpressionAttributeNames={"#state": "state"},
        ExpressionAttributeValues={":queued": "queued"},
    ):
        user_id, agent = row.get("userId"), row.get("agent")
        created = _parse_iso(row.get("createdAt"))
        if not user_id or not agent or created is None:
            continue
        key = (user_id, agent)
        if key not in oldest or created < oldest[key]:
            oldest[key] = created
    return [(u, a, t) for (u, a), t in oldest.items()]


def _any_live_site(user_id, agent, now):
    return bool(_live_sites(user_id, agent, now))


# --- entry point -------------------------------------------------------------


def _require_site_scope(event, method, parts):
    """A site token authenticates ONE body, and may only act as that body.

    Without this, a site token would be a full operator token for its owner's
    account: `_authorize` attaches the same `_userId`, and every route reads
    only that. The allow-list is therefore the whole boundary, and it is
    written as "deny unless explicitly listed" — a route added later is
    inaccessible to sites until someone decides it should be."""
    site_id = event.get("_siteId")
    if not site_id:
        return
    # Its own row: heartbeat and retire-self. Not /sites (enumerating its
    # siblings), not /sites/enroll (minting new bodies), not another site's id.
    if len(parts) >= 2 and parts[0] == "sites" and parts[1] == site_id:
        if (method == "POST" and len(parts) == 3 and parts[2] == "heartbeat") or (
            method == "DELETE" and len(parts) == 2
        ):
            return
    # Re-signing its own URLs, and telling its owner something happened. Both
    # are already scoped to `_userId` and neither can name another site.
    if method == "POST" and parts in (["presign"], ["notify"]):
        return
    # The claim protocol. Each handler re-checks that the message belongs to
    # this site's user AND agent, so a site can only ever act on its own queue.
    if method == "POST" and len(parts) == 3 and parts[0] == "messages" and parts[2] in ("claim", "ack", "register"):
        return
    # A body's own work, all scoped to `_userId` already: memory (remember/
    # recall/profile), transcript chunks, device status, feedback, reading
    # (never writing) the service-credential store, and its own agent's goals
    # ledger. This is what lets an EC2 instance boot with only a site token.
    if parts[:1] == ["memory"] or parts[:1] == ["transcript-chunk"] or parts[:1] == ["transcript-chunks"]:
        return
    if method == "GET" and parts in (["devices", "status"], ["secrets"]):
        return
    if method == "POST" and parts == ["feedback"]:
        return
    if len(parts) == 3 and parts[0] == "agents" and parts[2] == "goals":
        return
    raise ApiError(403, "a site token cannot use this route")


def _route(event):
    http = (event.get("requestContext") or {}).get("http") or {}
    method = str(http.get("method") or "").upper()
    path = str(event.get("rawPath") or http.get("path") or "/").rstrip("/") or "/"
    parts = [p for p in path.split("/") if p]

    _require_site_scope(event, method, parts)

    if method == "POST" and parts == ["sites", "enroll"]:
        return enroll_site(event)
    if method == "POST" and parts == ["sites", "enroll-tokens"]:
        return mint_enroll_token(event)
    if method == "GET" and len(parts) == 3 and parts[0] == "agents" and parts[2] == "goals":
        return get_goals(event, parts[1])
    if method == "PUT" and len(parts) == 3 and parts[0] == "agents" and parts[2] == "goals":
        return put_goals(event, parts[1])
    if method == "GET" and parts == ["sites"]:
        return list_sites(event)
    if method == "POST" and len(parts) == 3 and parts[0] == "sites" and parts[2] == "heartbeat":
        return site_heartbeat(event, parts[1])
    if method == "POST" and len(parts) == 3 and parts[0] == "sites" and parts[2] == "commands":
        return queue_site_command(event, parts[1])
    if method == "DELETE" and len(parts) == 2 and parts[0] == "sites":
        return delete_site(event, parts[1])
    if method == "POST" and parts == ["messages"]:
        return send_message(event)
    if method == "GET" and parts == ["messages"]:
        return list_messages(event)
    if method == "GET" and len(parts) == 2 and parts[0] == "messages":
        return get_message(event, parts[1])
    if method == "POST" and len(parts) == 3 and parts[0] == "messages" and parts[2] == "claim":
        return claim_message(event, parts[1])
    if method == "POST" and len(parts) == 3 and parts[0] == "messages" and parts[2] == "ack":
        return ack_message(event, parts[1])
    if method == "POST" and len(parts) == 3 and parts[0] == "messages" and parts[2] == "register":
        return register_message(event, parts[1])
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
    if method == "POST" and parts == ["wake"]:
        return _response(200, wake(event))
    if method == "PUT" and len(parts) == 3 and parts[0] == "inbox" and parts[2] == "lock":
        return claim_inbox_lock(event, parts[1])
    if method == "DELETE" and len(parts) == 3 and parts[0] == "inbox" and parts[2] == "lock":
        return release_inbox_lock(event, parts[1])
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
    if method == "PUT" and parts == ["transcript-chunk"]:
        return put_transcript_chunk(event)
    if method == "GET" and parts == ["transcript-chunks"]:
        return get_transcript_chunks(event)
    if method == "POST" and parts == ["memory"]:
        return put_memory_entry(event)
    if method == "GET" and parts == ["memory"]:
        return get_memory(event)
    if method == "PUT" and parts == ["memory", "profile", "lock"]:
        return claim_memory_profile_lock(event)
    if method == "DELETE" and parts == ["memory", "profile", "lock"]:
        return release_memory_profile_lock(event)
    if method == "GET" and parts == ["memory", "profile"]:
        return get_memory_profile(event)
    if method == "PUT" and parts == ["memory", "profile"]:
        return put_memory_profile(event)
    if method == "GET" and parts == ["devices", "status"]:
        return list_device_status(event)
    if method == "GET" and parts == ["artifacts"]:
        return list_artifacts(event)
    if method == "GET" and len(parts) >= 2 and parts[0] == "artifacts":
        return get_artifact(event, "/".join(parts[1:]))
    if method == "PUT" and len(parts) >= 2 and parts[0] == "artifacts":
        return put_artifact(event, "/".join(parts[1:]))
    if method == "DELETE" and len(parts) >= 2 and parts[0] == "artifacts":
        return delete_artifact(event, "/".join(parts[1:]))
    raise ApiError(404, "no route for {} {}".format(method or "?", path))


def lambda_handler(event, _context=None):
    event = event if isinstance(event, dict) else {}

    # EventBridge invokes the function directly, so there is no HTTP envelope to
    # authorize; the schedule's invoke permission is the authorization.
    if event.get("source") == "sweep-schedule":
        return sweep(event)
    if event.get("source") == "wake-schedule":
        return wake(event)

    http = (event.get("requestContext") or {}).get("http") or {}
    method = str(http.get("method") or "").upper()
    path = str(event.get("rawPath") or http.get("path") or "/").rstrip("/") or "/"
    parts = [p for p in path.split("/") if p]
    is_auth_route = method == "POST" and parts == ["auth", "apple"]
    # An installer redeeming a one-time enroll token has no bearer yet either;
    # the token IS its authorization (checked and consumed in enroll_with_token).
    is_token_enroll = (
        method == "POST" and parts == ["sites", "enroll"]
        and not _header(event, "authorization").strip()
    )

    try:
        if is_token_enroll:
            return enroll_with_token(event)
        if is_auth_route:
            # The one route with no bearer token to check yet — it's how one
            # is obtained. Apple's own identity-token verification IS this
            # route's authorization.
            return auth_apple(event)
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
