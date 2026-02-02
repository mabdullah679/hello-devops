#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-hello-devops-482600}"
REGION="${REGION:-us-east1}"
SERVICE="${SERVICE:-hello-devops}"
TOKEN="${TOKEN:-1}"

gcloud run services update "$SERVICE" \
  --project "$PROJECT_ID" \
  --region "$REGION" \
  --set-env-vars "REQUIRED_TOKEN=${TOKEN}"

URL="$(gcloud run services describe "$SERVICE" --project "$PROJECT_ID" --region "$REGION" --format='value(status.url)')"
if [[ -z "$URL" ]]; then
  echo "No Cloud Run URL found for service '$SERVICE'." >&2
  exit 1
fi

echo "URL: $URL"
curl -i "$URL/health"
