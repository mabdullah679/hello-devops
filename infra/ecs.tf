data "aws_ecr_repository" "app" {
  name = var.name_prefix
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.name_prefix}"
  retention_in_days = 7
}

resource "aws_ecs_cluster" "main" {
  name = "${var.name_prefix}-cluster"
}

# ---- IAM: execution role (pull image, write logs, read the secret) ------------
data "aws_iam_policy" "boundary" {
  name = "portfolio-ci-boundary"
}

data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name                 = "${var.name_prefix}-task-execution"
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_trust.json
  permissions_boundary = data.aws_iam_policy.boundary.arn
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secret" {
  name = "read-admin-token"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameters"]
      Resource = [aws_ssm_parameter.admin_token.arn]
    }]
  })
}

# ---- IAM: task role (what the app itself may do: read/flip the chaos flag only)
resource "aws_iam_role" "task" {
  name                 = "${var.name_prefix}-task"
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_trust.json
  permissions_boundary = data.aws_iam_policy.boundary.arn
}

resource "aws_iam_role_policy" "task_chaos" {
  name = "chaos-flag"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:PutParameter"]
      Resource = [aws_ssm_parameter.chaos.arn]
    }]
  })
}

# ---- Task definition + service ------------------------------------------------
resource "aws_ecs_task_definition" "app" {
  family                   = "${var.name_prefix}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name                   = "app"
    image                  = "${data.aws_ecr_repository.app.repository_url}:${var.image_tag}"
    essential              = true
    readonlyRootFilesystem = true
    user                   = "10001"
    stopTimeout            = 30
    portMappings           = [{ containerPort = 8080, protocol = "tcp" }]
    environment = [
      { name = "PORT", value = "8080" },
      { name = "APP_VERSION", value = var.image_tag },
      { name = "CHAOS_SSM_PARAM", value = aws_ssm_parameter.chaos.name },
      { name = "AWS_REGION", value = var.region },
      { name = "DRAIN_SECONDS", value = "5" },
    ]
    secrets = [{ name = "ADMIN_TOKEN", valueFrom = aws_ssm_parameter.admin_token.arn }]
    healthCheck = {
      command     = ["CMD", "python3", "-c", "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8080/livez',timeout=2)"]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 10
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "app"
      }
    }
  }])
}

resource "aws_ecs_service" "app" {
  name            = "${var.name_prefix}-svc"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # Rolling deploy: start new tasks first, never drop below full capacity.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 30
  wait_for_steady_state              = true

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = 8080
  }

  depends_on = [aws_lb_listener.http]
}
