# Fin: AWS migration out of the nonprofit account

Status: **draft plan, nothing executed** (2026-10-06). Nothing in the old account
may change until Levi approves.

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
