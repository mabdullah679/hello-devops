param(
  [string]$ProjectId = "hello-devops-482600",
  [string]$Service = "hello-devops",
  [int]$Limit = 50
)

$ErrorActionPreference = "Stop"

gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=$Service" `
  --project $ProjectID `
  --limit $Limit `
  --format "value(timestamp,textPayload)"

