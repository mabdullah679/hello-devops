#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-hello-devops-482600}"
SERVICE="${SERVICE:-hello-devops}"
LIMIT="${LIMIT:-50}"

gcloud logging read \
  "resource.type=cloud_run_revision AND resource.labels.service_name=${SERVICE}" \
  --project "$PROJECT_ID" \
  --limit "$LIMIT" \
  --format "value(timestamp,textPayload)"
