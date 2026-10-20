# Probe the service, show target health behind the ALB and alarm states.
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_common.ps1"
Show-Probe
(Invoke-WebRequest -Uri "$Url/" -UseBasicParsing).Content
$tg = aws elbv2 describe-target-groups --names "$NamePrefix-tg" --query 'TargetGroups[0].TargetGroupArn' --output text 2>$null
if ($tg -and $tg -ne "None") {
  Write-Host "Target health:"
  aws elbv2 describe-target-health --target-group-arn $tg --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' --output text
}
Write-Host "Alarms:"
aws cloudwatch describe-alarms --alarm-name-prefix $NamePrefix --query 'MetricAlarms[].[AlarmName,StateValue]' --output text
