#!/bin/bash
# Deploys the fin cloud-worker control plane: DynamoDB table, IAM role, Lambda,
# HTTP API, and the sweep schedule.
#
#   deploy.sh
#
# Idempotent — every create is guarded by an exists-check, so re-running only
# ships new code and re-puts the inline policy. The bearer token is generated
# once and reused from ~/.fin-control-plane-token on later runs; rotating it on
# every deploy would silently break every client. Export FIN_CP_TOKEN to force
# a specific token.
#
# Push notifications need one manual prerequisite: an APNs auth key (.p8) —
# see the "APNs auth key" section below. Absent, the deploy still succeeds and
# only POST /notify is dark (503).
set -euo pipefail

PROFILE=levi
REGION=us-west-2
FUNCTION=fin-control-plane
ROLE=fin-control-plane
TABLE=fin-cloud-workers
TOKENS_TABLE=fin-device-tokens
API_NAME=fin-control-plane
RULE=fin-worker-sweep
BUCKET=fin-agent-directives-011183829623
FACTORY_BUCKET=fin-model-factory-011183829623
AGENT_ROLE=fin-agent-ssm
TOKEN_FILE="$HOME/.fin-control-plane-token"
APNS_TEAM_ID="${APNS_TEAM_ID:-EC27UF79GL}"
APNS_TOPIC="${APNS_TOPIC:-dev.levischoen.fin}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

aws() { command aws --profile "$PROFILE" --region "$REGION" "$@"; }

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
LAMBDA_ARN="arn:aws:lambda:$REGION:$ACCOUNT:function:$FUNCTION"
ROLE_ARN="arn:aws:iam::$ACCOUNT:role/$ROLE"

# --- DynamoDB ----------------------------------------------------------------
if ! aws dynamodb describe-table --table-name "$TABLE" >/dev/null 2>&1; then
  aws dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=workerId,AttributeType=S \
    --key-schema AttributeName=workerId,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
  aws dynamodb wait table-exists --table-name "$TABLE"
  echo "==> Created DynamoDB table $TABLE (on-demand)"
fi

# APNs device tokens, one item per device, keyed by the token itself (dedupe by
# design — the app re-PUTs on every launch). Its own table, not an item-type in
# $TABLE: that table's rows ARE workers, and list_workers scans it whole.
if ! aws dynamodb describe-table --table-name "$TOKENS_TABLE" >/dev/null 2>&1; then
  aws dynamodb create-table \
    --table-name "$TOKENS_TABLE" \
    --attribute-definitions AttributeName=token,AttributeType=S \
    --key-schema AttributeName=token,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
  aws dynamodb wait table-exists --table-name "$TOKENS_TABLE"
  echo "==> Created DynamoDB table $TOKENS_TABLE (on-demand)"
fi

# --- model-factory data lake -------------------------------------------------
# Private bucket for training telemetry (see scripts/model-factory/README.md).
# raw/ expires after 180 days; datasets/, models/, and evals/ persist.
if ! aws s3api head-bucket --bucket "$FACTORY_BUCKET" >/dev/null 2>&1; then
  aws s3api create-bucket --bucket "$FACTORY_BUCKET" \
    --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  echo "==> Created S3 bucket $FACTORY_BUCKET"
fi
aws s3api put-public-access-block --bucket "$FACTORY_BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
cat > "$BUILD/lifecycle.json" <<'JSON'
{
  "Rules": [
    {
      "ID": "expire-raw-180d",
      "Status": "Enabled",
      "Filter": {"Prefix": "raw/"},
      "Expiration": {"Days": 180}
    }
  ]
}
JSON
aws s3api put-bucket-lifecycle-configuration --bucket "$FACTORY_BUCKET" \
  --lifecycle-configuration "file://$BUILD/lifecycle.json"

# --- IAM role ----------------------------------------------------------------
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  echo "==> Created IAM role $ROLE; waiting for propagation"
  sleep 12
fi

# TerminateInstances is fenced to instances carrying a fin-agent tag: the control
# plane can lose track of a worker, but it can never reach an unrelated instance.
# CreateTags is fenced to the RunInstances call that creates them.
# ServiceCredsWrite is deliberately WITHOUT secretsmanager:GetSecretValue: the
# API is write-only in IAM, not just in code — reads belong to the worker role
# (fin-agent-ssm, granted in ../launch.sh).
# AutoProvisionConfigs is fenced to *.json under fin/agentd/ on purpose: the
# Lambda instantiates per-agent configs from the template, but it can never
# replace the fin-agentd binary that lives beside them.
# SeeMissingAgentObjects (s3:ListBucket, fin/* prefix only) exists so a
# HeadObject/GetObject of an absent key answers 404/NoSuchKey instead of 403
# Forbidden — without it the auto-provision head-check can never see a miss.
cat > "$BUILD/policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LaunchAndInspect",
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:DescribeInstances",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeImages"
      ],
      "Resource": "*"
    },
    {
      "Sid": "TagOnLaunch",
      "Effect": "Allow",
      "Action": "ec2:CreateTags",
      "Resource": "*",
      "Condition": {"StringEquals": {"ec2:CreateAction": "RunInstances"}}
    },
    {
      "Sid": "TerminateFinAgentsOnly",
      "Effect": "Allow",
      "Action": "ec2:TerminateInstances",
      "Resource": "*",
      "Condition": {"StringLike": {"ec2:ResourceTag/fin-agent": "*"}}
    },
    {
      "Sid": "PassAgentInstanceProfile",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::$ACCOUNT:role/$AGENT_ROLE",
      "Condition": {"StringEquals": {"iam:PassedToService": "ec2.amazonaws.com"}}
    },
    {
      "Sid": "ResolveAL2023Ami",
      "Effect": "Allow",
      "Action": ["ssm:GetParameter", "ssm:GetParameters"],
      "Resource": "arn:aws:ssm:$REGION::parameter/aws/service/ami-amazon-linux-latest/*"
    },
    {
      "Sid": "WorkerRecords",
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:Query",
        "dynamodb:Scan"
      ],
      "Resource": "arn:aws:dynamodb:$REGION:$ACCOUNT:table/$TABLE"
    },
    {
      "Sid": "DeviceTokenRecords",
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:Scan"
      ],
      "Resource": "arn:aws:dynamodb:$REGION:$ACCOUNT:table/$TOKENS_TABLE"
    },
    {
      "Sid": "AgentObjects",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::$BUCKET/fin/*"
    },
    {
      "Sid": "SeeMissingAgentObjects",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::$BUCKET",
      "Condition": {"StringLike": {"s3:prefix": "fin/*"}}
    },
    {
      "Effect": "Allow",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::$BUCKET/fin/inbox/*"
    },
    {
      "Sid": "AutoProvisionConfigs",
      "Effect": "Allow",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::$BUCKET/fin/agentd/*.json"
    },
    {
      "Sid": "ModelFactoryIngest",
      "Effect": "Allow",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::$FACTORY_BUCKET/raw/*"
    },
    {
      "Sid": "ServiceCredsWrite",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:CreateSecret",
        "secretsmanager:PutSecretValue",
        "secretsmanager:UpdateSecret",
        "secretsmanager:TagResource",
        "secretsmanager:DescribeSecret",
        "secretsmanager:DeleteSecret",
        "secretsmanager:RestoreSecret"
      ],
      "Resource": "arn:aws:secretsmanager:$REGION:$ACCOUNT:secret:fin/service-creds/*"
    },
    {
      "Sid": "ServiceCredsList",
      "Effect": "Allow",
      "Action": "secretsmanager:ListSecrets",
      "Resource": "*"
    },
    {
      "Sid": "Logs",
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:$REGION:$ACCOUNT:*"
    }
  ]
}
JSON
aws iam put-role-policy --role-name "$ROLE" --policy-name fin-control-plane \
  --policy-document "file://$BUILD/policy.json"

# --- bearer token ------------------------------------------------------------
if [ -n "${FIN_CP_TOKEN:-}" ]; then
  TOKEN="$FIN_CP_TOKEN"
  echo "==> Using FIN_CP_TOKEN from the environment"
elif [ -s "$TOKEN_FILE" ]; then
  TOKEN=$(command cat "$TOKEN_FILE")
else
  TOKEN=$(openssl rand -hex 32)
  (umask 077; printf '%s\n' "$TOKEN" > "$TOKEN_FILE")
  chmod 600 "$TOKEN_FILE"
  echo "==> Generated a new API token and saved it to $TOKEN_FILE (chmod 600)"
fi

# --- APNs auth key (optional) ------------------------------------------------
# The ONE manual prerequisite for push: an APNs auth key, created once at
# developer.apple.com → Certificates, Identifiers & Profiles → Keys → "+",
# with "Apple Push Notifications service (APNs)" checked, then downloaded as
# AuthKey_<KEYID>.p8 — Apple hands the file out exactly once, at creation.
# Point FIN_APNS_KEY_PATH at it, or drop it in ~/.appstoreconnect/apns/.
# Absent, the deploy proceeds without the APNS_* env and POST /notify answers
# 503; every other route is unaffected.
APNS_KEY_FILE="${FIN_APNS_KEY_PATH:-}"
if [ -z "$APNS_KEY_FILE" ]; then
  APNS_KEY_FILE=$(ls -t "$HOME"/.appstoreconnect/apns/AuthKey_*.p8 2>/dev/null | head -n 1 || true)
fi
APNS_KEY_ID=""
if [ -n "$APNS_KEY_FILE" ] && [ -s "$APNS_KEY_FILE" ]; then
  APNS_KEY_ID=$(basename "$APNS_KEY_FILE" | sed -n 's/^AuthKey_\([A-Z0-9]\{10\}\)\.p8$/\1/p')
  if [ -z "$APNS_KEY_ID" ]; then
    echo "==> $APNS_KEY_FILE is not named AuthKey_<KEYID>.p8; deploying without push credentials" >&2
    APNS_KEY_FILE=""
  else
    echo "==> APNs push enabled: key $APNS_KEY_ID, topic $APNS_TOPIC"
  fi
else
  APNS_KEY_FILE=""
  echo "==> No APNs auth key (set FIN_APNS_KEY_PATH or drop AuthKey_<KEYID>.p8 in ~/.appstoreconnect/apns/)"
  echo "    Deploying without push credentials: POST /notify will answer 503."
fi

# The token and the .p8 content go to the CLI through a file inside the 0700
# build dir, never on a command line where ps would show them.
FIN_CP_TOKEN_VALUE="$TOKEN" APNS_KEY_FILE="$APNS_KEY_FILE" APNS_KEY_ID="$APNS_KEY_ID" \
  APNS_TEAM_ID="$APNS_TEAM_ID" APNS_TOPIC="$APNS_TOPIC" \
  python3 - "$BUILD/env.json" <<'PY'
import json, os, sys

variables = {"FIN_CP_TOKEN": os.environ["FIN_CP_TOKEN_VALUE"]}
key_file = os.environ.get("APNS_KEY_FILE")
if key_file:
    with open(key_file) as handle:
        variables.update(
            APNS_KEY=handle.read(),
            APNS_KEY_ID=os.environ["APNS_KEY_ID"],
            APNS_TEAM_ID=os.environ["APNS_TEAM_ID"],
            APNS_TOPIC=os.environ["APNS_TOPIC"],
        )
with open(sys.argv[1], "w") as handle:
    json.dump({"Variables": variables}, handle)
PY

# --- Lambda ------------------------------------------------------------------
# Packaged as lambda_function.py: `lambda` is a reserved word, so nothing that
# parses the handler string has to cope with a module named after a keyword.
# The zip vendors the /notify dependencies: APNs speaks only HTTP/2 and the
# stdlib has no HTTP/2 client, so httpx+h2 ride along, plus ecdsa for the ES256
# provider JWT. All pure python on purpose — no compiled wheels, so a zip built
# on any machine runs unchanged on the arm64 python3.12 runtime.
PKG="$BUILD/pkg"
mkdir -p "$PKG"
python3 -m pip install --quiet --no-compile --target "$PKG" 'httpx[http2]' ecdsa
cp "$HERE/lambda.py" "$PKG/lambda_function.py"
(cd "$PKG" && zip -qr "$BUILD/lambda.zip" . -x 'bin/*')

if aws lambda get-function --function-name "$FUNCTION" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$FUNCTION" \
    --zip-file "fileb://$BUILD/lambda.zip" --architectures arm64 >/dev/null
  aws lambda wait function-updated --function-name "$FUNCTION"
  aws lambda update-function-configuration --function-name "$FUNCTION" \
    --role "$ROLE_ARN" --runtime python3.12 --handler lambda_function.lambda_handler \
    --timeout 60 --memory-size 256 --environment "file://$BUILD/env.json" >/dev/null
  aws lambda wait function-updated --function-name "$FUNCTION"
  echo "==> Updated Lambda $FUNCTION"
else
  # A freshly created role is not assumable for a few seconds.
  CREATED=""
  for _ in 1 2 3 4 5; do
    if aws lambda create-function --function-name "$FUNCTION" \
      --runtime python3.12 --architectures arm64 --role "$ROLE_ARN" \
      --handler lambda_function.lambda_handler --timeout 60 --memory-size 256 \
      --environment "file://$BUILD/env.json" \
      --zip-file "fileb://$BUILD/lambda.zip" >/dev/null 2>"$BUILD/create.err"; then
      CREATED=1
      break
    fi
    grep -q "cannot be assumed" "$BUILD/create.err" || break
    sleep 6
  done
  if [ -z "$CREATED" ]; then
    command cat "$BUILD/create.err" >&2
    exit 1
  fi
  aws lambda wait function-active-v2 --function-name "$FUNCTION"
  echo "==> Created Lambda $FUNCTION"
fi

# --- HTTP API ----------------------------------------------------------------
API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='$API_NAME'].ApiId | [0]" --output text)
if [ "$API_ID" = "None" ] || [ -z "$API_ID" ]; then
  API_ID=$(aws apigatewayv2 create-api --name "$API_NAME" --protocol-type HTTP \
    --description "fin cloud-worker control plane" --query ApiId --output text)
  echo "==> Created HTTP API $API_ID"
fi

INTEGRATION_ID=$(aws apigatewayv2 get-integrations --api-id "$API_ID" \
  --query "Items[?IntegrationUri=='$LAMBDA_ARN'].IntegrationId | [0]" --output text)
if [ "$INTEGRATION_ID" = "None" ] || [ -z "$INTEGRATION_ID" ]; then
  INTEGRATION_ID=$(aws apigatewayv2 create-integration --api-id "$API_ID" \
    --integration-type AWS_PROXY --integration-uri "$LAMBDA_ARN" \
    --integration-method POST --payload-format-version 2.0 \
    --query IntegrationId --output text)
  echo "==> Created AWS_PROXY integration $INTEGRATION_ID"
fi

while read -r ROUTE_KEY; do
  [ -n "$ROUTE_KEY" ] || continue
  EXISTING=$(aws apigatewayv2 get-routes --api-id "$API_ID" \
    --query "Items[?RouteKey=='$ROUTE_KEY'].RouteId | [0]" --output text)
  if [ "$EXISTING" = "None" ] || [ -z "$EXISTING" ]; then
    aws apigatewayv2 create-route --api-id "$API_ID" --route-key "$ROUTE_KEY" \
      --target "integrations/$INTEGRATION_ID" >/dev/null
    echo "==> Created route $ROUTE_KEY"
  fi
done <<'ROUTES'
POST /workers
GET /workers
DELETE /workers/{workerId}
GET /usage
POST /sweep
POST /presign
POST /feedback
PUT /secrets/{service}
GET /secrets
DELETE /secrets/{service}
PUT /device-tokens
POST /notify
ROUTES

if ! aws apigatewayv2 get-stage --api-id "$API_ID" --stage-name '$default' >/dev/null 2>&1; then
  aws apigatewayv2 create-stage --api-id "$API_ID" --stage-name '$default' --auto-deploy >/dev/null
  echo '==> Created $default stage (auto-deploy)'
fi

# --- sweep schedule ----------------------------------------------------------
if ! aws events describe-rule --name "$RULE" >/dev/null 2>&1; then
  aws events put-rule --name "$RULE" --schedule-expression 'rate(10 minutes)' \
    --description "terminate idle fin cloud workers" >/dev/null
  echo "==> Created EventBridge rule $RULE"
fi

cat > "$BUILD/target.json" <<JSON
[{"Id": "fin-control-plane", "Arn": "$LAMBDA_ARN", "Input": "{\"source\": \"sweep-schedule\"}"}]
JSON
aws events put-targets --rule "$RULE" --targets "file://$BUILD/target.json" >/dev/null

# --- invoke permissions ------------------------------------------------------
POLICY=$(aws lambda get-policy --function-name "$FUNCTION" --query Policy --output text 2>/dev/null || echo "")
case "$POLICY" in
  *fin-cp-api*) ;;
  *) aws lambda add-permission --function-name "$FUNCTION" --statement-id fin-cp-api \
       --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
       --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT:$API_ID/*/*" >/dev/null
     echo "==> Allowed the HTTP API to invoke $FUNCTION" ;;
esac
case "$POLICY" in
  *fin-cp-sweep*) ;;
  *) aws lambda add-permission --function-name "$FUNCTION" --statement-id fin-cp-sweep \
       --action lambda:InvokeFunction --principal events.amazonaws.com \
       --source-arn "arn:aws:events:$REGION:$ACCOUNT:rule/$RULE" >/dev/null
     echo "==> Allowed $RULE to invoke $FUNCTION" ;;
esac

ENDPOINT=$(aws apigatewayv2 get-api --api-id "$API_ID" --query ApiEndpoint --output text)
echo
echo "==> Control plane ready"
echo "    Endpoint: $ENDPOINT"
echo "    Token:    $TOKEN_FILE"
echo "    Smoke:    curl -sS -H \"authorization: Bearer \$(cat $TOKEN_FILE)\" $ENDPOINT/workers"
