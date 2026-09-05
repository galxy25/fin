#!/bin/bash
# Launches ONE isolated EC2 instance hosting ONE fin-agentd cloud agent.
#
#   launch.sh <agent-name> <config-s3-key> [instance-type] [browser]
#
# Pass the literal word "browser" as the 4th argument to install headless
# chromium + playwright (python) at boot — use t4g.small or larger for that;
# chromium in 0.5–1 GiB dies on memory.
#
# The instance is the agent's whole sandbox: the daemon SSHes to ITSELF
# (localhost) and works inside a local tmux session, so nothing else is
# reachable from the agent's terminal. Networking is egress-only — no inbound
# rules at all; admin access is SSM Session Manager, never SSH.
#
# Prereqs (one-time, this script creates them if missing):
#   - security group fin-agent-egress (no ingress)
#   - IAM role/profile fin-agent-ssm (AmazonSSMManagedInstanceCore only)
# The daemon binary and its config are fetched at boot via the PRESIGNED URLs
# stored in the config object's companion bootstrap file — the instance role
# deliberately has NO S3 permissions; every S3 capability the agent holds is a
# presigned URL with an expiry.
set -euo pipefail

PROFILE=levi
REGION=us-west-2
BUCKET=fin-agent-directives-011183829623
AGENT_NAME="${1:?usage: launch.sh <agent-name> <config-s3-key> [instance-type] [browser]}"
CONFIG_KEY="${2:?usage: launch.sh <agent-name> <config-s3-key> [instance-type] [browser]}"
INSTANCE_TYPE="${3:-t4g.micro}"
WITH_BROWSER="${4:-}"
if [ -n "$WITH_BROWSER" ] && [ "$WITH_BROWSER" != "browser" ]; then
  echo "4th argument must be the literal word 'browser' (or omitted)" >&2
  exit 1
fi
if [ "$WITH_BROWSER" = "browser" ] && { [ "$INSTANCE_TYPE" = "t4g.nano" ] || [ "$INSTANCE_TYPE" = "t4g.micro" ]; }; then
  echo "browser workers need t4g.small or larger; chromium on $INSTANCE_TYPE dies on memory" >&2
  exit 1
fi
# "shared" is reserved as the everyone-readable secret scope under
# fin/service-creds/; an agent by that name would collide with it.
if [ "$(printf '%s' "$AGENT_NAME" | tr '[:upper:]' '[:lower:]')" = "shared" ]; then
  echo "agent name 'shared' is reserved for the shared secret scope" >&2
  exit 1
fi

aws() { command aws --profile "$PROFILE" --region "$REGION" "$@"; }

# --- security group (egress-only) -------------------------------------------
SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values=fin-agent-egress \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo None)
if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  VPC_ID=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true \
    --query 'Vpcs[0].VpcId' --output text)
  SG_ID=$(aws ec2 create-security-group \
    --group-name fin-agent-egress \
    --description "fin cloud agents: egress only, no ingress" \
    --vpc-id "$VPC_ID" --query GroupId --output text)
  echo "==> Created security group $SG_ID (egress-only)"
fi

# --- SSM instance profile ----------------------------------------------------
if ! aws iam get-instance-profile --instance-profile-name fin-agent-ssm >/dev/null 2>&1; then
  aws iam create-role --role-name fin-agent-ssm \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name fin-agent-ssm \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam create-instance-profile --instance-profile-name fin-agent-ssm >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name fin-agent-ssm \
    --role-name fin-agent-ssm
  echo "==> Created IAM role/profile fin-agent-ssm (SSM only); waiting for propagation"
  sleep 12
fi

# --- worker read path for service credentials --------------------------------
# The ONLY credential permission a worker holds: GetSecretValue on the
# fin/service-creds/ prefix. Writes stay with the control-plane Lambda, which
# itself cannot read — the write/read split is enforced in IAM, not code.
# put-role-policy is idempotent and runs unconditionally so a role created by
# an earlier version of this script picks the policy up on the next launch.
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
CREDS_READ_POLICY=$(cat <<JSON
{"Version": "2012-10-17",
 "Statement": [{"Sid": "ServiceCredsRead",
   "Effect": "Allow",
   "Action": "secretsmanager:GetSecretValue",
   "Resource": "arn:aws:secretsmanager:$REGION:$ACCOUNT:secret:fin/service-creds/*"}]}
JSON
)
aws iam put-role-policy --role-name fin-agent-ssm \
  --policy-name fin-agent-service-creds --policy-document "$CREDS_READ_POLICY"

# --- boot material: presigned fetch URLs for binary + config -----------------
# 7-day expiry: the instance only fetches at boot; a rebuild re-presigns.
BINARY_URL=$(aws s3 presign "s3://$BUCKET/fin/agentd/fin-agentd" --expires-in 604800)
CONFIG_URL=$(aws s3 presign "s3://$BUCKET/$CONFIG_KEY" --expires-in 604800)

AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
  --query Parameter.Value --output text)

USER_DATA=$(cat <<EOF
#!/bin/bash
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
curl -fsSL -o /opt/fin-agentd/fin-agentd '$BINARY_URL'
curl -fsSL -o /opt/fin-agentd/config.json '$CONFIG_URL'
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
EOF
)

# Byte-for-byte the optional browser block from control-plane/lambda.py
# (BROWSER_USER_DATA) — any change here belongs there too. Runs AFTER the
# harness is enabled so the chromium download never delays the status object
# the sweep's boot grace waits on.
if [ "$WITH_BROWSER" = "browser" ]; then
USER_DATA+="
$(cat <<'BROWSER'
# --- headless browser (playwright + chromium) --------------------------------
# Idempotent: dnf and pip skip what is already present; playwright install is a
# no-op once the pinned chromium build is cached under ~fin-agent.
dnf install -y python3 python3-pip \
  alsa-lib at-spi2-atk at-spi2-core atk cairo cups-libs dbus-libs expat glib2 \
  libdrm libX11 libXcomposite libXdamage libXext libXfixes libXrandr libxcb \
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
BROWSER
)"
fi

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --security-group-ids "$SG_ID" \
  --iam-instance-profile Name=fin-agent-ssm \
  --user-data "$USER_DATA" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=fin-agent-$AGENT_NAME},{Key=fin-agent,Value=$AGENT_NAME}]" \
  --metadata-options HttpTokens=required \
  --count 1 \
  --query 'Instances[0].InstanceId' --output text)

echo "==> Launched $INSTANCE_ID ($INSTANCE_TYPE) for agent '$AGENT_NAME'"
echo "    Watch:     aws --profile $PROFILE --region $REGION ec2 describe-instances --instance-ids $INSTANCE_ID --query 'Reservations[0].Instances[0].State.Name'"
echo "    Shell:     aws --profile $PROFILE --region $REGION ssm start-session --target $INSTANCE_ID"
echo "    Terminate: scripts/cloud-agent/terminate.sh $AGENT_NAME"
