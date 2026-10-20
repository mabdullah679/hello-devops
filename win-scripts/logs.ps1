# Recent app logs from CloudWatch (JSON lines). Set $env:SINCE (default 15m).
if (-not $env:AWS_REGION) { $env:AWS_REGION = "ap-southeast-2" }
$p = if ($env:NAME_PREFIX) { $env:NAME_PREFIX } else { "pf-hello-devops" }
$since = if ($env:SINCE) { $env:SINCE } else { "15m" }
aws logs tail "/ecs/$p" --since $since --format short
