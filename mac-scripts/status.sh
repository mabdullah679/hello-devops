#!/usr/bin/env bash
# Probe the service, show target health behind the ALB and alarm states.
set -euo pipefail
source "$(dirname "$0")/_common.sh"
probe
curl -s -m 5 "$URL/"
TG="$(terraform -chdir="$ROOT/infra" output -raw target_group 2>/dev/null || true)"
if [[ -n "$TG" ]]; then
  echo "Target health:"
  aws elbv2 describe-target-health --target-group-arn "$TG" \
    --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' --output text
fi
echo "Alarms:"
aws cloudwatch describe-alarms --alarm-name-prefix "$NAME_PREFIX" \
  --query 'MetricAlarms[].[AlarmName,StateValue]' --output text
