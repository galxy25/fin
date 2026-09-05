# Cloud agent hosting

One `fin-agentd` harness per agent, each on its own isolated EC2 Graviton
instance (default `t4g.micro`). The instance is the agent's whole sandbox: the
daemon SSHes to `localhost` and works inside a local tmux session. Models are
never hosted here — the harness only calls out to a custom OpenAI-dialect
endpoint (`agent.endpointURL` in its config), e.g. an LM Studio box exposed
over HTTPS with bearer auth.

All I/O rides S3 objects addressed by presigned SigV4 URLs (7-day max expiry —
re-presign and update the config/app on rotation):

| object                        | writer      | reader      | purpose |
|-------------------------------|-------------|-------------|---------|
| `fin/directives.json`         | supervisor  | harness     | supervisor commands |
| `fin/inbox/<agent>.json`      | iOS app     | harness     | user messages (compose in the cloud console) |
| `fin/status.json`             | harness     | supervisor  | health + last turn |
| `fin/transcripts/<agent>.jsonl`| harness    | iOS app     | rolling mirror-format transcript the remote console renders |
| `fin/agentd/fin-agentd`       | build host  | instance    | the aarch64-linux binary (boot fetch) |
| `fin/agentd/<agent>.json`     | operator or control plane | instance | the harness config (boot fetch) |
| `fin/agentd/_template.json`   | `make-config-template.sh` | control plane | auto-provisioning template for agents with no config |

Flow: `build-linux.sh` → upload binary + per-agent config (with its presigned
URLs inline) to S3 → `launch.sh <agent> fin/agentd/<agent>.json` → instance
boots, systemd starts the harness with `stayResident`, transcript begins
flowing. In the app, set the agent's Hosting to Cloud Harness and paste the
transcript GET + inbox GET/PUT URLs. Agents nobody hand-provisioned still
launch: `POST /workers` instantiates `fin/agentd/_template.json` on the fly
(generate it once with `make-config-template.sh`; see "Auto-provisioning" in
`control-plane/README.md`, sharp edges included).

Security posture: security group has no ingress; admin access is SSM Session
Manager only; the instance role carries SSM plus exactly one credential grant —
`secretsmanager:GetSecretValue` on `fin/service-creds/*` (no S3 — every S3
capability is a presigned URL with an expiry); IMDSv2 required. The per-agent
config holds the LLM endpoint bearer token — treat configs as secrets, never
commit one.

Service credentials (Gmail app passwords, API keys, …) are stored through the
control plane's write-only `/secrets` API and read on-instance from Secrets
Manager under `fin/service-creds/<scope>/<service>`; the control plane cannot
read them back and never returns a value. One reserved service rides that
store: `fin-agent-ssh-key` (shared scope) is Fin's own SSH identity, generated
in the app under "Fin's Key" — when present, the boot script installs its
private key at `/home/fin-agent/.ssh/fin_agent_ed25519` (0600, `fin-agent`)
before the daemon starts, so a config's `server.privateKeyPath` can point
there; absent, the boot is unchanged. The bootstrap lives in two copies
(`launch.sh` and the Lambda's `USER_DATA`) — `check-userdata-parity.py`
verifies they stay byte-identical. Optional headless browser: pass the
literal word `browser` as `launch.sh`'s 4th argument, or `"browser": true` on
`POST /workers`, to install chromium + playwright (python) at boot — t4g.small
or larger. `browser-smoke.py` is the empirical check that the browser stack
works on a given instance. Details: `control-plane/README.md`.
