resource "random_password" "admin_token" {
  length  = 40
  special = false
}

# Runtime secret, injected into the container by ECS (never in the task definition).
resource "aws_ssm_parameter" "admin_token" {
  name  = "/${var.name_prefix}/admin-token"
  type  = "SecureString"
  value = random_password.admin_token.result
}

# Shared chaos flag read by every task. ignore_changes: a deploy must not silently
# reset a deliberate break.
resource "aws_ssm_parameter" "chaos" {
  name  = "/${var.name_prefix}/chaos"
  type  = "String"
  value = "ok"
  lifecycle {
    ignore_changes = [value]
  }
}
