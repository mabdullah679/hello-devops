# Put the service into chaos mode: /healthz and /readyz return 503 on every task.
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_common.ps1"
Set-Chaos "break"
Start-Sleep -Seconds 4
Show-Probe
