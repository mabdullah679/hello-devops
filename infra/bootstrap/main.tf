# Bootstrap: things that must exist BEFORE the main stack / pipeline can run.
#   - S3 bucket for the main stack's Terraform state
#   - ECR repository (the pipeline pushes the image before terraform apply)
#   - the IAM role GitHub Actions assumes through OIDC (no stored AWS keys)
# This stack is applied by hand (it creates the role the pipeline needs, so the
# pipeline cannot create it) and uses local state. Destroy it LAST.
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "name_prefix" {
  type    = string
  default = "pf-hello-devops"
}

variable "region" {
  type    = string
  default = "ap-southeast-2"
}

variable "github_repo" {
  type    = string
  default = "mabdullah679/hello-devops"
}

# Only these git refs may assume the deploy role.
variable "allowed_refs" {
  type    = list(string)
  default = ["refs/heads/prod-hardening"]
}

provider "aws" {
  region              = var.region
  allowed_account_ids = ["346208529954"]
  default_tags {
    tags = {
      project    = "portfolio"
      repo       = "hello-devops"
      managed-by = "terraform"
    }
  }
}

data "aws_caller_identity" "me" {}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy" "boundary" {
  name = "portfolio-ci-boundary"
}

locals {
  account_id = data.aws_caller_identity.me.account_id
}

# ---------------------------------------------------------------- state bucket
resource "aws_s3_bucket" "state" {
  bucket        = "${var.name_prefix}-tfstate-${local.account_id}"
  force_destroy = true # versioned state history is disposable once the project is torn down
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ------------------------------------------------------------------------- ECR
resource "aws_ecr_repository" "app" {
  name                 = var.name_prefix
  image_tag_mutability = "IMMUTABLE" # a sha tag always means the same bytes
  force_delete         = true
  image_scanning_configuration {
    scan_on_push = true
  }
  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep the last 10 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

# ------------------------------------------------------- GitHub OIDC deploy role
data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for r in var.allowed_refs : "repo:${var.github_repo}:ref:${r}"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "${var.name_prefix}-github-deploy"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  permissions_boundary = data.aws_iam_policy.boundary.arn
  max_session_duration = 3600
}

data "aws_iam_policy_document" "deploy" {
  # Terraform state
  statement {
    sid       = "StateBucketList"
    actions   = ["s3:ListBucket", "s3:GetBucketVersioning"]
    resources = [aws_s3_bucket.state.arn]
  }
  statement {
    sid       = "StateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }

  # Image push (this repository only)
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages", "ecr:DescribeRepositories", "ecr:ListTagsForResource",
      "ecr:GetLifecyclePolicy", "ecr:GetRepositoryPolicy", "ecr:DescribeImageScanFindings",
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  # Resources that cannot be scoped at create time (EC2/ELB/ECS create APIs take no
  # resource ARN) are limited to the region instead; the prefix is enforced by
  # Terraform naming and by the IAM / SSM / Logs / Lambda statements below.
  statement {
    sid = "NetworkingComputeRegionScoped"
    actions = [
      "ec2:*", "elasticloadbalancing:*", "ecs:*", "cloudwatch:*", "sns:*", "events:*",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid       = "PrefixedLogs"
    actions   = ["logs:*"]
    resources = ["arn:aws:logs:${var.region}:${local.account_id}:log-group:/*${var.name_prefix}*", "arn:aws:logs:${var.region}:${local.account_id}:log-group:/*${var.name_prefix}*:*"]
  }
  statement {
    sid       = "LogsDescribe"
    actions   = ["logs:DescribeLogGroups", "logs:ListTagsForResource", "logs:ListTagsLogGroup"]
    resources = ["*"]
  }
  statement {
    sid       = "PrefixedLambda"
    actions   = ["lambda:*"]
    resources = ["arn:aws:lambda:${var.region}:${local.account_id}:function:${var.name_prefix}-*"]
  }
  statement {
    sid       = "PrefixedSsm"
    actions   = ["ssm:*"]
    resources = ["arn:aws:ssm:${var.region}:${local.account_id}:parameter/${var.name_prefix}/*"]
  }
  statement {
    sid       = "SsmDescribe"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }
  statement {
    sid       = "ReadOnlyLookups"
    actions   = ["iam:GetOpenIDConnectProvider", "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicies", "sts:GetCallerIdentity"]
    resources = ["*"]
  }

  # ECS and ELB create their service-linked roles on first use (none exist yet).
  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/aws-service-role/*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["ecs.amazonaws.com", "elasticloadbalancing.amazonaws.com"]
    }
  }

  # IAM: only roles/policies carrying the prefix, and new roles MUST carry the boundary.
  statement {
    sid     = "PrefixedRolesCreate"
    actions = ["iam:CreateRole"]
    resources = [
      "arn:aws:iam::${local.account_id}:role/${var.name_prefix}-*",
    ]
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [data.aws_iam_policy.boundary.arn]
    }
  }
  statement {
    sid = "PrefixedRolesManage"
    actions = [
      "iam:GetRole", "iam:DeleteRole", "iam:UpdateRole", "iam:TagRole", "iam:UntagRole",
      "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy", "iam:ListRolePolicies",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole", "iam:UpdateAssumeRolePolicy", "iam:PassRole",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.name_prefix}-*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}

output "state_bucket" { value = aws_s3_bucket.state.bucket }
output "ecr_repository_url" { value = aws_ecr_repository.app.repository_url }
output "deploy_role_arn" { value = aws_iam_role.deploy.arn }
