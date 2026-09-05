# Cloud-worker control plane

A serverless front door for the cloud agents `../launch.sh` launches by hand: one
Lambda (`lambda.py`) behind an API Gateway HTTP API, a DynamoDB table of worker
records (`fin-cloud-workers`), and an EventBridge schedule that terminates idle
workers every 10 minutes.

Launching through the API produces the same instance `launch.sh` does — AL2023
arm64 from the SSM alias, the egress-only `fin-agent-egress` group, the SSM-only
`fin-agent-ssm` profile, IMDSv2 required, binary and config fetched at boot over
presigned URLs — plus the tags the sweep needs (`fin-managed=control-plane`,
`fin-idle-minutes`). The presigned URLs are signed by the Lambda role and expire
in an hour; the instance role still holds no S3 permission of its own.

```
./deploy.sh          # idempotent; prints the endpoint and the token file path
```

`deploy.sh` needs the `fin-agent-egress` security group and the `fin-agent-ssm`
instance profile to exist. `launch.sh` creates both on its first run; the Lambda
deliberately cannot, and answers 503 if either is missing.

## Routes

Every route needs `authorization: Bearer <token>`. The token lives in
`~/.fin-control-plane-token` (mode 600) — read it from the file, never paste it
into a command line or a commit.

```sh
API=https://<api-id>.execute-api.us-west-2.amazonaws.com
AUTH="authorization: Bearer $(cat ~/.fin-control-plane-token)"

# launch a worker (instanceType defaults to t4g.nano, idleMinutes to 30)
curl -sS -X POST "$API/workers" -H "$AUTH" -H 'content-type: application/json' \
  -d '{"agent": "fin-agentd-1", "instanceType": "t4g.micro", "idleMinutes": 45}'

# every worker, live and dead, most recent first, with uptimeSeconds
curl -sS "$API/workers" -H "$AUTH"

# terminate one
curl -sS -X DELETE "$API/workers/<workerId>" -H "$AUTH"

# uptime and estimated spend, per agent and per instance type
curl -sS "$API/usage" -H "$AUTH"

# run the idle sweep now instead of waiting for the schedule
curl -sS -X POST "$API/sweep" -H "$AUTH"

# vend short-lived presigned S3 URLs (kinds and agent both optional)
curl -sS -X POST "$API/presign" -H "$AUTH" -H 'content-type: application/json' \
  -d '{"agent": "Nimbus", "kinds": ["inbox", "supervisionDirective"]}'

# model-factory ingest: opt-in, pre-redacted app telemetry (FROZEN contract —
# see scripts/model-factory/README.md for the full spec and privacy rules)
curl -sS -X POST "$API/feedback" -H "$AUTH" -H 'content-type: application/json' \
  -d '{"kind": "user_feedback", "rating": 1, "comment": "routed correctly",
       "payload": null, "appVersion": "1.4.0", "platform": "ios",
       "createdAt": "2026-09-05T17:00:00Z"}'
```

`POST /workers` refuses with 409 when the agent already has a live worker, and
with 400 when there is no config at `fin/agentd/<agent>.json` (the instance would
boot, fail the fetch, and bill for nothing). `instanceType` is restricted to the
priced t4g sizes below. Note the default is `t4g.nano`, one size below
`launch.sh`'s manual `t4g.micro` — nano's 0.5 GiB is tight for the harness, so
pass `instanceType` explicitly if a worker dies on memory.

## Presigned URLs

`POST /presign` hands the app the same kind of short-lived S3 URLs the launch
bootstrap uses, so the app can read and write the agent's channel objects without
holding any S3 permission of its own. The body is `{ "agent": "<name>", "kinds":
[...] }` and both fields are optional:

- `kinds` omitted returns every kind the request can satisfy — the agent-scoped
  kinds only when `agent` is present, the supervision kinds always.
- `agent` must match the `[A-Za-z0-9][A-Za-z0-9._-]{0,62}` name rule (the same one
  `POST /workers` enforces, so a presign can never traverse out of the key space).
  It is required for `transcript`, `inbox`, and `status`, and ignored for the
  app-wide supervision kinds.

The five kinds map to these objects and methods:

| kind | object | response fields |
| --- | --- | --- |
| `transcript` | `fin/transcripts/<agent>.jsonl` | `transcriptGet` |
| `inbox` | `fin/inbox/<agent>.json` | `inboxGet`, `inboxPut` |
| `status` | `fin/status-<agent>.json` | `statusGet` |
| `supervisionDirective` | `fin/directives.json` | `supervisionDirectiveGet` |
| `supervisionStatus` | `fin/status.json` | `supervisionStatusPut` |

The 200 body is `{ "generatedAt", "expiresAt", "ttlSeconds", "urls": {...} }`,
with only the requested (or applicable) fields present under `urls`. The URLs are
signed by the Lambda role and expire in an hour — but like the boot URLs they die
with the Lambda's temporary credentials even before that, so the app re-requests
on demand rather than caching them. An unknown kind, or an agent-scoped kind with
a missing or malformed `agent`, is a 400.

## Model-factory ingest

`POST /feedback` is the app's one door into the model-factory data lake
(`fin-model-factory-011183829623` — a separate bucket from the agent channel,
with a 180-day expiry on `raw/`). The body contract is **frozen** and specified
in `scripts/model-factory/README.md`; the Lambda validates it, wraps it with a
server `receivedAt` and an id, and writes one JSON object to
`raw/feedback/YYYY/MM/DD/<uuid>.json` (or `raw/trajectories/...` for
`"kind": "trajectory"`). 400 on a contract violation, 401 unauthenticated, 413
over 1 MiB. Everything the app sends is opt-in and pre-redacted before upload;
comment and payload content is never logged.

## How the sweep decides

The schedule invokes the Lambda directly every 10 minutes (`POST /sweep` runs the
same code). For each live worker it reads `fin/status-<agent>.json` and applies,
in order:

- **No status object.** Terminated only after 45 minutes from launch — before
  that the instance may still be installing packages and fetching the binary.
- **Stale status.** `updated_at` older than the worker's idle window. The harness
  PUTs status after every poll, so a stale stamp means the daemon is dead,
  wedged, or cut off from the bucket.
- **Idle.** `state` is `idle` or `task-complete` and the last real turn
  (`last_turn_at`, or launch time for a worker that never took one) is older than
  the idle window. The clock cannot run off `updated_at` here: a healthy idle
  daemon refreshes that every poll, so it never goes stale on its own.

All three stamp `terminatedReason: "idle-sweep"`; the sweep's response carries the
specific reason per worker. The idle window is the worker's `idleMinutes`, which
is also written to the instance as the `fin-idle-minutes` tag.

The sweep also **adopts** any running instance tagged `fin-agent` with no live
record — a worker launched by hand with `launch.sh` gets a record (backfilled
from its `LaunchTime`, idle window from its tag or 30 minutes) and is swept from
then on. And it **reconciles**: a record whose instance EC2 no longer reports gets
stamped `instance-gone`, so `/usage` stops accruing hours for a dead worker.

## Prices are estimates

`/usage` multiplies uptime by a hardcoded us-west-2 on-demand map — `t4g.nano`
0.0042, `t4g.micro` 0.0084, `t4g.small` 0.0168, `t4g.medium` 0.0336 $/hr. This
exists to calibrate subscription pricing and is **not billing truth**: it ignores
Savings Plans, Spot, EBS, data transfer, and free-tier credit. Adopted workers of
an unpriced type contribute 0 to the totals and are listed under
`unpricedInstanceTypes`.

## Fallbacks

`../launch.sh` and `../terminate.sh` still work and remain the manual path — use
them when the control plane is down, when you need an instance type outside the
priced set, or when you would rather not have a record at all. Anything launched
that way is adopted by the next sweep, so it is still subject to the idle window;
tag the instance `fin-idle-minutes` if you want a window other than 30 minutes.
