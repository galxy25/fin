# Fin: AWS migration out of the nonprofit account

Status: **cut over to green 2026-10-12 23:59Z; the one-week watch was dropped, and blue is torn down 2026-10-14 (see Teardown).** Fin now
runs from the LLC account 623170744161 (profile `llc`); the old account only
forwards. See "Cutover state" at the bottom for exactly what is where and how to
roll back.

## Why

Account 011183829623 is `AFRICANINTELLECTCLUB`, the nonprofit's account, and will
receive a TechSoup credit. Non-nonprofit workloads must move out (private-benefit
issue). Levi decided Fin and PocketDJ move OUT; the nonprofit stays. Inventory:
`africanintellect/infra/aws-cost-split-2026-10-05.md`.

## What Fin has in the old account

- S3: `fin-agent-directives-011183829623` (689 MB: supervision/inbox/transcripts,
  site status, goals), `fin-model-factory-011183829623`, `fin-africanintellect-legal`
- CloudFront `E2XD8RL8PK64SX` (`fin.africanintellect.ai`), serving the live
  privacy policy and terms
- Lambda `fin-control-plane` (200 MB log group), API Gateway `fin-control-plane`
  (`vzrf1bf59g`), 11 DynamoDB `fin-*` tables
- EventBridge `fin-worker-sweep`, `fin-worker-wake`; two `fin/...ssh-key` secrets
- IAM role/profile `fin-agent-ssm`; one EBS snapshot and one AMI; default VPC
- No EC2 running. The August compute spend (~$43) was short-lived worker instances.

## Findings (verified in this repo)

- **Shipped apps and the daemon do NOT hardcode the control-plane URL.** The
  endpoint is runtime config: iCloud Key-Value Storage via `SyncedDeviceConfig`
  (tvOS reads the same slot), token in the iCloud keychain; the daemon reads
  `config.controlPlane.endpointURL`. A new endpoint needs no app release.
- The URL literal and the account-id-bearing bucket names live only in scripts
  and docs: `scripts/cloud-agent/launch.sh`, `control-plane/deploy.sh`,
  `scripts/mac-fin-agentd/provision-config.sh`,
  `scripts/mac-wake-for-fin/wake-for-fin.py`, `docs/SITES.md`, `lambda.py`.
- **Shipped builds do hardcode** `https://fin.africanintellect.ai/terms` and
  `/privacy` (`fin/Views/PaywallView.swift`), and App Store listings reference
  them. The hostname must keep serving them throughout.
- DNS for `africanintellect.ai` is at **Hover** (NS: ns1/ns2.hover.com), not
  Route 53. `fin.africanintellect.ai` is a CNAME to a CloudFront domain, so
  cutover is a Hover record edit.

## Things that bite

- Bucket names are global and embed the account id: the new account needs new
  names; parameterise instead of hardcoding.
- ACM certs for CloudFront are per account (us-east-1) and cannot be transferred;
  issue a new one for `fin.africanintellect.ai` (DNS validation record at Hover).
- The control-plane URL changes (new API Gateway id): enrolled Macs' daemon
  configs need the new endpoint (site-command queue or `provision-config.sh`);
  synced device config is rewritten once. Bearer and site tokens, and the tvOS key
  vault ciphertext / SIWA account rows, live in DynamoDB/S3 and must move with it.
- Copy with the control plane quiesced to avoid losing writes.
- Secrets hold SSH keys: copy securely, never print.
- Disable the old `fin-worker-sweep` / `fin-worker-wake` at cutover or they keep
  launching workers in the old account (2026-09-10 wake-sweep incident).
- New accounts start with low vCPU quotas (worker types m7i.large, c7g.2xlarge,
  t4g.nano, Spot) and may need Bedrock/model access requests.
- Rebuild the worker AMI in the new account via `launch.sh` rather than copying.
- This repo is going public: new account id and bucket names must not carry
  secrets; keep them in config, not committed credentials.

## Plan

0. **Levi:** create the new account (see list below). Send account id + profile name.
1. **Fin agent, new account only:** parameterise account/bucket names; deploy
   buckets, DynamoDB, IAM, Lambda + API Gateway via `deploy.sh`; create secrets;
   ACM cert + new CloudFront for `fin.africanintellect.ai`; rebuild AMI.
2. **Dry run:** point one test site at the new control plane and run an
   end-to-end thread. Old stack stays live and untouched.
3. **Cutover (Levi approves):** quiesce Fin, final S3 sync + DynamoDB
   export/import, switch Hover CNAME, push new endpoint to the three Macs and
   synced config, disable old EventBridge rules. Daemon/app update is optional.
4. **Watch one week** with the old stack read-only, then delete Fin resources
   from 011183829623 with Levi's explicit OK.

## Levi-only list

- Create the new AWS account (standalone signup preferred; Organizations would
  make the nonprofit account the management account), payment method, root MFA
- Admin IAM user and CLI profile (suggested name `fin`; do not reuse the old
  `Developer` user / profile `levi`)
- Quota increases and Bedrock/model access requests
- Hover DNS edits (ACM validation record, cutover CNAME)
- Approve cutover, the maintenance window, and the final deletion
- App Store / TestFlight submissions still need Levi's word

## Estimate

Phases 1-2 about a day of agent work; cutover a short window; one-week watch.

## During the one-week watch (what stays in the old account)

Old Fin stack kept read-only/idle as rollback: buckets, DynamoDB tables, Lambda,
API Gateway, CloudFront distribution E2XD8RL8PK64SX and secrets stay, with
EventBridge rules disabled. The legal bucket/CloudFront must keep serving until
the Hover CNAME points at the new distribution and is verified.

## Cutover state (2026-10-12)

Levi asked (via the africanintellect `non-profit` session) for a green build in
623170744161 and a blue/green switch. Done as follows; every step is a command in
this repo.

| | Blue (011183829623, profile `levi`) | Green (623170744161, profile `llc`) |
|---|---|---|
| Control plane | `vzrf1bf59g`, Lambda env `FIN_CP_FORWARD_TO` = green: relays every request, schedules no-op | `https://evnlvth1ih.execute-api.us-west-2.amazonaws.com`, the live one |
| EventBridge sweep/wake | DISABLED | ENABLED |
| Agent bucket | `fin-agent-directives-011183829623`, frozen at 23:59Z | `fin-agent-directives-623170744161` |
| Legal pages | `fin-africanintellect-legal` + CloudFront E2XD8RL8PK64SX (alias removed 2026-10-13) | `fin-legal-623170744161` + CloudFront E1HBK154BB5YYF (`d3tvnxu2y5galq.cloudfront.net`), holds `fin.africanintellect.ai` with green's ACM cert |

- Data: `scripts/cloud-agent/migrate-account.py all --delete` (final) then
  `--missing-only` (catch-up) after the forwarder went live. The relay cert was
  copied, not regenerated, so the shipped pin (`6886b52b…`) holds.
- Hover: `fin` CNAME now points at green; `_fin` TXT and the ACM validation CNAME
  stay. CloudFront refuses a cross-account `associate-alias` while the source is
  enabled. With Levi's OK, on 2026-10-13 at 04:29Z the alias was removed from blue's
  distribution and added to green's 3 s later. Green was Deployed at 04:30Z, and
  /privacy, /terms and /support serve 200 under green's Oct-12 cert.
- Sites: iMac re-pointed directly (config.json endpoint plus
  `provision-config.sh --refresh` against the green bucket; backup
  `config.json.bak-pre-llc`), and `wake-for-fin` now defaults to profile `llc`.
  MacBook Neo has a queued `run-shell` that rewrites its endpoint; it takes
  effect on its next daemon restart, and the forwarder carries it until then.
- Apps: their endpoint is iCloud KVS (`CloudControlPlaneConfig`) and only the app
  can write it. Until someone edits it in one device's settings, apps reach green
  through the forwarder.
- Verified: every read route matched blue; an app-style message round-tripped
  (queued, claimed by the iMac, answered `pong (new account)`); a terminal relay
  launched in green, served the pinned cert, and the iMac paired.

Traps hit (fixed in code):
- A bucket younger than about a day isn't in global S3 DNS. Presigned URLs on
  `bucket.s3.amazonaws.com` reach us-east-1 and get 400
  AuthorizationQueryParametersError. lambda.py and provision-config.sh now sign
  regional virtual-hosted URLs.
- The new account is on AWS's **Free plan**: EC2 refuses `t4g.nano` ("not
  eligible for Free Tier"). Green runs relays/workers on `t4g.micro` via
  `FIN_CP_RELAY_INSTANCE_TYPE`/`FIN_CP_DEFAULT_INSTANCE_TYPE` (re-pass them on
  every deploy until the account is upgraded to a paid plan; a Free-plan account
  is closed when its credits run out). The EC2 on-demand vCPU quota is 5.

Deploying now:
- green: `control-plane/deploy.sh` (the account was upgraded to a paid plan on 2026-10-13: t4g.nano is accepted again, the vCPU quota is 16, and the t4g.micro overrides are gone)
- blue (only ever like this during the watch):
  `FIN_AWS_PROFILE=levi FIN_CP_FORWARD_TO=https://evnlvth1ih.execute-api.us-west-2.amazonaws.com control-plane/deploy.sh`

Rollback to blue:
1. `FIN_SRC_PROFILE=llc FIN_DST_PROFILE=levi scripts/cloud-agent/migrate-account.py all --delete`
   (green's writes since cutover go back to blue).
2. `FIN_AWS_PROFILE=levi control-plane/deploy.sh` with no `FIN_CP_FORWARD_TO`,
   which stops the forwarding. Enable blue's two rules and disable green's.
3. iMac: restore `config.json.bak-pre-llc`, run `FIN_AWS_PROFILE=levi provision-config.sh --refresh`,
   `launchctl kickstart -k gui/$UID/dev.levischoen.fin.agentd`, restart wake with
   `FIN_WAKE_PROFILE=levi`. Neo: queue the reverse endpoint edit.
4. Legal pages (only if needed; green's distribution can keep serving them): remove the alias from E1HBK154BB5YYF, add it back on E2XD8RL8PK64SX, and point the Hover `fin` CNAME back to `d1neu32b2sn1ez.cloudfront.net`.

After the week, with Levi's explicit OK: delete Fin's resources in 011183829623.

## Teardown of blue (2026-10-14)

Levi dropped the one-week watch: switch over hard, then remove every Fin
resource from 011183829623 so the nonprofit can redeem its TechSoup credit.
Message the `non-profit` session when it's done.

Gate: nothing must still be calling blue. A temporary access log on blue's
API stage (`/fin/blue-access-temp`, 1-day retention) records the caller,
path and user agent. On 2026-10-13 everything still reaching blue came from
the Fin apps, through the iCloud KVS endpoint; the daemons have already moved.
1. Levi sets the control-plane endpoint in one device's Fin settings to
   `https://evnlvth1ih.execute-api.us-west-2.amazonaws.com`, and every device's
   app picks it up. Then `/fin/blue-access-temp` shows no new requests for
   30+ minutes.
2. Verify green end to end: run a message round trip, launch a relay, check
   that /privacy, /terms and /support return 200, and check that every live
   site has a fresh `lastHeartbeatAt` in green `fin-sites`.
3. Final safety copy: `FIN_SRC_PROFILE=levi FIN_DST_PROFILE=llc migrate-account.py all --missing-only`
   should add nothing.

Delete (profile `levi`, us-west-2 unless noted). This is the full inventory taken
2026-10-13. The only AMI/snapshot/key pair in the account is PocketDJ's, so leave it:
- EventBridge `fin-worker-sweep`, `fin-worker-wake` (remove targets first)
- Lambda `fin-control-plane`, plus log groups `/aws/lambda/fin-control-plane` and `/fin/blue-access-temp`
- API Gateway `vzrf1bf59g`
- DynamoDB: the 10 `fin-*` tables (no deletion protection, no backups)
- S3 `fin-agent-directives-011183829623`, `fin-model-factory-011183829623`,
  and `fin-africanintellect-legal` (us-east-1). None are versioned.
- Secrets `fin/service-creds/shared/fin-agent-ssh-key` and
  `users/6aa33866-…/fin/service-creds/shared/fin-agent-ssh-key`. Delete with
  `--force-delete-without-recovery` so nothing lingers.
- IAM: role `fin-control-plane` (inline policy); role and instance profile
  `fin-agent-ssm` (AmazonSSMManagedInstanceCore + inline `fin-agent-service-creds`)
- Security groups `fin-relay-ingress`, `fin-agent-egress`
- CloudFront `E2XD8RL8PK64SX` (disable, wait for Deployed, delete), OAC
  `fin-legal-oac`, and the ACM cert for `fin.africanintellect.ai` in us-east-1
  (`be280be8-…`)

After the teardown, rollback is no longer possible. Remove the blue
`FIN_CP_FORWARD_TO` instructions above and drop `levi` as a fallback profile in the scripts.
