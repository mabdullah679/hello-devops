param(
  [string]$ProjectId = "hello-devops-482600",
  [string]$Service = "hello-devops",
  [string]$Region = "us-east1",
  [string]$Token = "1"
)

$ErrorActionPreference = "Stop"

gcloud run services update $Service `
  --project $ProjectID `
  --region $Region `
  --set-env-vars REQUIRED_TOKEN=$Token

$url = gcloud run services describe $Service --project $ProjectId --region $Region --format "value(status.url)"
Write-Host "URL: $url"
curl.exe -i "$url/health"