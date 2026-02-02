param(
    [string]$ProjectID = "hello-devops-482600",
    [string]$Region = "us-east1",
    [string]$Service = "hello-devops"
)

$ErrorActionPreference = "Stop"

$url = gcloud run services describe $Service --project $ProjectID --region $Region --format "value(status.url)"
if (-not $url) { throw "No Cloud URL found for Service '$Service'."}

Write-Host "URL: $url"
curl.exe -i $url/health