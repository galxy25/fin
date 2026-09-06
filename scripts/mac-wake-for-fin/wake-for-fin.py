#!/usr/bin/env python3
"""Keep this Mac reachable while Fin is working — without lighting the display.

This iMac is Fin's local LLM host: cloud workers and on-device agents route their
inference turns over the Tailscale Funnel to the bearer shim in front of LM Studio
(see scripts/cloud-agent/lmstudio-auth-shim.py). If the Mac sleeps, that route dies
and no turn can be served. This resident poller keeps the machine awake *only while
Fin actually has work*, and lets it sleep the rest of the time.

Mechanism — `caffeinate`, not a hand-rolled IOKit assertion:

    /usr/bin/caffeinate -i -m -s -w <poller-pid>

  -i  prevent idle SYSTEM sleep — this is the one that keeps the network stack,
      tailscaled, the shim and LM Studio up and reachable.
  -s  prevent forced system sleep. The man page limits -s to AC power; this is a
      desktop iMac (always AC, no battery, no lid), so -s is always honored.
  -m  prevent disk idle sleep (belt-and-suspenders; harmless).
  NO -d — the display is deliberately left on its normal timer: the screen goes
      dark while the machine stays awake behind it. That is exactly "reachable
      without lighting the display."
  NO -u — never declare user activity; -u can poke the display awake.
  -w <poller-pid> — a dead-man switch: caffeinate self-exits when this poller's pid
      disappears, so the assertion can NEVER outlive the daemon, even on SIGKILL
      where a signal handler would not run. On a graceful idle-release the poller
      also terminates the child itself.

IOKit assertions (and thus caffeinate's) are reference-counted and additive: this
assertion is independent of anyone else's, and releasing ours never touches theirs.

Activity signal (any one keeps the Mac awake), re-checked every ~30s:
  * a LIVE cloud worker in the DynamoDB control-plane table — it will route turns here;
  * any agent inbox under fin/inbox/*.json with a non-empty `directives` array —
    queued work that is about to burn an LLM turn;
  * any status object fin/status*.json touched within the freshness window — an
    agent (device or daemon) that PUTs status every poll is alive and working.
Once none of these has been true for the idle timeout (~10 min), the assertion is
released and the Mac is free to sleep.

Honest limitation: a truly-sleeping Mac cannot poll S3 or serve inference. A message
that lands while the Mac is already asleep is invisible until the Mac next wakes on
its own. Closing that cold-sleep gap needs a scheduled `pmset` wake (root, coarse) —
see install.sh and README.md; this daemon never touches power state directly.

Robustness: transient AWS/network errors are caught and logged, never fatal — the
loop continues. A failed signal check counts as "inactive for that signal" but does
not force a release on its own; the idle timer keeps running, so a persistent outage
(the whole channel is down anyway) eventually lets the Mac sleep. Secrets are never
logged: only booleans, counts and object keys reach the log — never inbox/directive
content, never config, never a token.

Config via environment (sane defaults for this iMac):
  FIN_WAKE_PROFILE               AWS profile          (default "levi")
  FIN_WAKE_REGION                AWS region           (default "us-west-2")
  FIN_WAKE_BUCKET                supervision bucket   (default fin-agent-directives-011183829623)
  FIN_WAKE_TABLE                 control-plane table  (default "fin-cloud-workers")
  FIN_WAKE_POLL_SECONDS          poll cadence         (default 30)
  FIN_WAKE_IDLE_SECONDS          release after idle   (default 600 = 10 min)
  FIN_WAKE_STATUS_FRESH_SECONDS  status "fresh" window (default 300 = 5 min)
  FIN_WAKE_LOG                   transition logfile   (default ~/Library/Logs/fin-wake.log)
"""

import json
import logging
import os
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone

import boto3
from botocore.exceptions import BotoCoreError, ClientError

PROFILE = os.environ.get("FIN_WAKE_PROFILE", "levi")
REGION = os.environ.get("FIN_WAKE_REGION", "us-west-2")
BUCKET = os.environ.get("FIN_WAKE_BUCKET", "fin-agent-directives-011183829623")
TABLE_NAME = os.environ.get("FIN_WAKE_TABLE", "fin-cloud-workers")


def _int_env(name, default):
    try:
        value = int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default
    return value if value > 0 else default


POLL_SECONDS = _int_env("FIN_WAKE_POLL_SECONDS", 30)
IDLE_SECONDS = _int_env("FIN_WAKE_IDLE_SECONDS", 600)
STATUS_FRESH_SECONDS = _int_env("FIN_WAKE_STATUS_FRESH_SECONDS", 300)
LOG_PATH = os.environ.get("FIN_WAKE_LOG") or os.path.expanduser("~/Library/Logs/fin-wake.log")

# "fin/status" matches both the app-wide supervision status (fin/status.json) and
# every per-agent status (fin/status-<agent>.json); it never matches fin/inbox/.
STATUS_PREFIX = "fin/status"
INBOX_PREFIX = "fin/inbox/"
CAFFEINATE = "/usr/bin/caffeinate"

# Cap the per-poll object fan-out so a future explosion of agents can't turn one
# tick into thousands of GETs.
MAX_INBOX_GETS = 200


def _make_logger():
    logger = logging.getLogger("fin-wake")
    logger.setLevel(logging.INFO)
    formatter = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        file_handler = logging.FileHandler(LOG_PATH)
        file_handler.setFormatter(formatter)
        logger.addHandler(file_handler)
    except OSError as exc:
        # A logfile we cannot open is not fatal — launchd still captures stdout.
        sys.stderr.write("fin-wake: cannot open logfile {}: {}\n".format(LOG_PATH, exc))
    stream_handler = logging.StreamHandler(sys.stdout)
    stream_handler.setFormatter(formatter)
    logger.addHandler(stream_handler)
    return logger


LOG = _make_logger()

_SESSION = boto3.session.Session(profile_name=PROFILE, region_name=REGION)
S3 = _SESSION.client("s3")
DDB = _SESSION.client("dynamodb")

# Error-log throttle: only log a signal's failure when the failure changes, and a
# single recovery line when it clears — so a persistent outage costs one line, not
# one every poll.
_signal_errors = {}


def _signal_failed(name, exc):
    kind = type(exc).__name__
    if _signal_errors.get(name) != kind:
        _signal_errors[name] = kind
        LOG.warning("signal %s check failed (%s); treating as inactive, idle timer continues", name, kind)


def _signal_recovered(name):
    if _signal_errors.pop(name, None) is not None:
        LOG.info("signal %s check recovered", name)


def any_live_worker():
    """True if the control-plane table holds any worker with status == 'live'."""
    try:
        start_key = None
        while True:
            kwargs = {
                "TableName": TABLE_NAME,
                "Select": "COUNT",
                "FilterExpression": "#s = :live",
                "ExpressionAttributeNames": {"#s": "status"},
                "ExpressionAttributeValues": {":live": {"S": "live"}},
            }
            if start_key:
                kwargs["ExclusiveStartKey"] = start_key
            resp = DDB.scan(**kwargs)
            if resp.get("Count", 0) > 0:
                _signal_recovered("live-worker")
                return True
            start_key = resp.get("LastEvaluatedKey")
            if not start_key:
                break
        _signal_recovered("live-worker")
        return False
    except (ClientError, BotoCoreError) as exc:
        _signal_failed("live-worker", exc)
        return False


def any_inbox_nonempty():
    """True if any fin/inbox/*.json carries a non-empty `directives` array."""
    try:
        gets = 0
        paginator = S3.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=BUCKET, Prefix=INBOX_PREFIX):
            for obj in page.get("Contents", []):
                key = obj.get("Key", "")
                if not key.endswith(".json"):
                    continue
                if gets >= MAX_INBOX_GETS:
                    break
                gets += 1
                body = S3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
                try:
                    doc = json.loads(body)
                except ValueError:
                    continue
                if isinstance(doc, dict):
                    directives = doc.get("directives")
                    # Content (directive text) is NEVER logged — only its presence.
                    if isinstance(directives, list) and directives:
                        _signal_recovered("inbox")
                        return True
        _signal_recovered("inbox")
        return False
    except (ClientError, BotoCoreError) as exc:
        _signal_failed("inbox", exc)
        return False


def any_status_fresh():
    """True if any fin/status*.json was written within the freshness window.

    S3 LastModified is the moment of the last PUT, and an agent (device or daemon)
    PUTs its status every poll — so an advancing LastModified is a live heartbeat,
    read from one cheap list call with no object GET and no content parsing."""
    try:
        now = datetime.now(timezone.utc)
        paginator = S3.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=BUCKET, Prefix=STATUS_PREFIX):
            for obj in page.get("Contents", []):
                if not obj.get("Key", "").endswith(".json"):
                    continue
                modified = obj.get("LastModified")
                if modified and (now - modified).total_seconds() <= STATUS_FRESH_SECONDS:
                    _signal_recovered("status-fresh")
                    return True
        _signal_recovered("status-fresh")
        return False
    except (ClientError, BotoCoreError) as exc:
        _signal_failed("status-fresh", exc)
        return False


def compute_active():
    """(active, [reasons]). Each signal is guarded independently: one signal's
    failure counts as inactive-for-that-signal but never masks another or aborts
    the whole check — so a DynamoDB blip can't hide a non-empty inbox."""
    reasons = []
    if any_live_worker():
        reasons.append("live-worker")
    if any_inbox_nonempty():
        reasons.append("inbox")
    if any_status_fresh():
        reasons.append("status-fresh")
    return bool(reasons), reasons


class Caffeinator:
    """Owns the single caffeinate child that holds the power assertion."""

    def __init__(self):
        self._proc = None

    @property
    def held(self):
        return self._proc is not None and self._proc.poll() is None

    def acquire(self, reasons):
        if self.held:
            return
        try:
            # -w our own pid: the assertion dies with this poller no matter how it
            # exits. No -d (display sleeps normally); no -u (never wake the display).
            self._proc = subprocess.Popen(
                [CAFFEINATE, "-i", "-m", "-s", "-w", str(os.getpid())]
            )
        except OSError as exc:
            self._proc = None
            LOG.warning("could not start caffeinate (%s); will retry next active poll", type(exc).__name__)
            return
        LOG.info(
            "assert: holding power assertion (caffeinate pid %d) — system+disk sleep off, display untouched — active: %s",
            self._proc.pid, ", ".join(reasons),
        )

    def release(self, reason="idle timeout"):
        if not self.held:
            self._proc = None
            return
        proc = self._proc
        self._proc = None
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        LOG.info("release: dropped power assertion (%s) — Mac may sleep", reason)


def main():
    LOG.info(
        "fin-wake starting: poll=%ds idle=%ds status-fresh=%ds bucket=%s table=%s profile=%s region=%s",
        POLL_SECONDS, IDLE_SECONDS, STATUS_FRESH_SECONDS, BUCKET, TABLE_NAME, PROFILE, REGION,
    )
    caffeinator = Caffeinator()
    stop = {"flag": False}

    def _handle_term(_signum, _frame):
        stop["flag"] = True

    signal.signal(signal.SIGTERM, _handle_term)
    signal.signal(signal.SIGINT, _handle_term)

    last_active = None  # monotonic time we last saw activity; None => never yet
    try:
        while not stop["flag"]:
            active, reasons = compute_active()
            now = time.monotonic()
            if active:
                last_active = now
                if not caffeinator.held:
                    caffeinator.acquire(reasons)
            elif caffeinator.held and last_active is not None and (now - last_active) >= IDLE_SECONDS:
                caffeinator.release()

            # Sleep in 1s slices so a SIGTERM is acted on promptly.
            slept = 0
            while slept < POLL_SECONDS and not stop["flag"]:
                time.sleep(1)
                slept += 1
    finally:
        caffeinator.release("shutdown")
        LOG.info("fin-wake stopping")


if __name__ == "__main__":
    main()
