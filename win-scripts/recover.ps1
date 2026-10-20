# Clear chaos mode: health returns to 200.
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_common.ps1"
Set-Chaos "recover"
Start-Sleep -Seconds 4
Show-Probe
