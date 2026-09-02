#!/bin/bash
# Terminates the EC2 instance(s) hosting a named cloud agent.
#   terminate.sh <agent-name>
set -euo pipefail

PROFILE=levi
REGION=us-west-2
AGENT_NAME="${1:?usage: terminate.sh <agent-name>}"

IDS=$(aws --profile "$PROFILE" --region "$REGION" ec2 describe-instances \
  --filters "Name=tag:fin-agent,Values=$AGENT_NAME" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)

if [ -z "$IDS" ]; then
  echo "No live instances tagged fin-agent=$AGENT_NAME"
  exit 0
fi

aws --profile "$PROFILE" --region "$REGION" ec2 terminate-instances \
  --instance-ids $IDS --query 'TerminatingInstances[].[InstanceId,CurrentState.Name]' \
  --output text
