param(
  [string]$ProjectID = "hello-devops-482600",
  [string]$Service = "hello-devops",
  [string]$Region = "us-east1"
)

$ErrorActionPreference = "Stop"

gcloud run services update $Service `
  --project $ProjectID `
  --region $Region `
  --set-env-vars REQUIRED_TOKEN=

$url = gcloud run services describe $Service --project $ProjectID --region $Region --format "value(status.url)"
if (-not $url) { throw "No Cloud Run URL found for service '$Service'." }


Write-Host "URL: $url"
curl.exe -i "$url/health"