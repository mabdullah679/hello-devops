# Dot-sourced by the other scripts. Resolves URL / token without ever printing the token.
if (-not $env:AWS_REGION) { $env:AWS_REGION = "ap-southeast-2" }
$NamePrefix = if ($env:NAME_PREFIX) { $env:NAME_PREFIX } else { "pf-hello-devops" }

# Needs only the AWS CLI (no terraform): the ALB is found by name.
$Url = $env:URL
if (-not $Url) {
  $dns = aws elbv2 describe-load-balancers --names "$NamePrefix-alb" --query 'LoadBalancers[0].DNSName' --output text 2>$null
  if ($dns -and $dns -ne "None") { $Url = "http://$dns" }
}
if (-not $Url) { throw "No URL: stack not deployed, or set `$env:URL = 'http://<alb-dns>'." }

function Get-AdminToken {
  aws ssm get-parameter --name "/$NamePrefix/admin-token" --with-decryption --query Parameter.Value --output text
}

function Set-Chaos([string]$State) {
  $headers = @{ Authorization = "Bearer $(Get-AdminToken)" }
  try {
    $r = Invoke-WebRequest -Method Post -Uri "$Url/admin/chaos" -Headers $headers `
      -ContentType "application/json" -Body (@{ state = $State } | ConvertTo-Json -Compress) -UseBasicParsing
    Write-Host "POST /admin/chaos {state:$State} -> HTTP $($r.StatusCode) $($r.Content.Trim())"
  } catch {
    Write-Host "POST /admin/chaos failed: $($_.Exception.Message)"; exit 1
  }
}

function Get-Code([string]$Path) {
  try { (Invoke-WebRequest -Uri "$Url$Path" -UseBasicParsing -TimeoutSec 5).StatusCode }
  catch { if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 } }
}

function Show-Probe {
  Write-Host "URL: $Url"
  foreach ($p in "/healthz", "/readyz") { Write-Host "GET $p -> HTTP $(Get-Code $p)" }
}
