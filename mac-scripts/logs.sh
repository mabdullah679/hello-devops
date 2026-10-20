#!/usr/bin/env bash
# Recent app logs from CloudWatch (JSON lines). LIMIT minutes of history via SINCE (default 15m).
set -euo pipefail
export AWS_REGION="${AWS_REGION:-ap-southeast-2}"
NAME_PREFIX="${NAME_PREFIX:-pf-hello-devops}"
aws logs tail "/ecs/${NAME_PREFIX}" --since "${SINCE:-15m}" --format short
