output "url" {
  value = "http://${aws_lb.main.dns_name}"
}
output "cluster" { value = aws_ecs_cluster.main.name }
output "service" { value = aws_ecs_service.app.name }
output "log_group" { value = aws_cloudwatch_log_group.app.name }
output "admin_token_param" { value = aws_ssm_parameter.admin_token.name }
output "chaos_param" { value = aws_ssm_parameter.chaos.name }
output "alarm_topic_arn" { value = aws_sns_topic.alerts.arn }
output "target_group" { value = aws_lb_target_group.app.arn }
