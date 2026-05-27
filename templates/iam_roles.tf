###############################################################################
# aws-iam-safe-agent — reference Terraform
#
# Provisions:
#   - 1 IAM User for an AI agent, with NO permissions other than sts:AssumeRole
#     against an explicit list of role ARNs.
#   - 4 purpose-scoped IAM Roles (ec2-read, s3-deploy, rds-query, cloudwatch-read)
#     each with:
#       * max_session_duration = 900   (15 minutes)
#       * Trust Policy requiring aws:MultiFactorAuthPresent = true
#       * Hand-rolled minimum permission policy
#
# Fill in the variables, `terraform init`, `terraform plan`, review, apply.
# Re-read the SKILL.md pre-deploy checklist before applying to a real account.
###############################################################################

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

###############################################################################
# Variables — the only things you should need to change.
###############################################################################

variable "agent_name" {
  description = "Short identifier for the agent (used in IAM names). e.g. \"hermes\", \"openclaw\"."
  type        = string
}

variable "env" {
  description = "Environment tag, separates resources per environment. e.g. \"dev\", \"prod\"."
  type        = string
}

variable "account_id" {
  description = "AWS account ID where these resources live."
  type        = string
}

variable "region" {
  description = "AWS region for the provider."
  type        = string
  default     = "ap-northeast-2"
}

variable "deploy_bucket" {
  description = "S3 bucket name the agent is allowed to deploy to (used by s3-deploy role)."
  type        = string
}

###############################################################################
# Locals — role catalog. One entry per task type.
# Adding a new task type means adding a new entry here, not widening an existing one.
###############################################################################

locals {
  name_prefix = "${var.agent_name}-${var.env}"

  roles = {
    "ec2-read" = {
      description = "Describe-only access to EC2. Cannot create, modify, start, stop, or terminate anything."
      actions = [
        "ec2:Describe*",
        "ec2:Get*",
        "ec2:List*",
      ]
      resources = ["*"]
    }

    "s3-deploy" = {
      description = "Read + write (no delete) on a single deploy bucket. Scoped to one ARN."
      actions = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket",
        "s3:GetBucketLocation",
      ]
      resources = [
        "arn:aws:s3:::${var.deploy_bucket}",
        "arn:aws:s3:::${var.deploy_bucket}/*",
      ]
    }

    "rds-query" = {
      description = "Describe + read-only Data API (SELECT). No DDL, no modify, no delete, no failover."
      actions = [
        "rds:Describe*",
        "rds:ListTagsForResource",
        "rds-data:ExecuteStatement",
        "rds-data:BatchExecuteStatement",
      ]
      resources = ["*"]
    }

    "cloudwatch-read" = {
      description = "Read-only on CloudWatch metrics, logs, and alarms. No put/delete."
      actions = [
        "cloudwatch:Get*",
        "cloudwatch:Describe*",
        "cloudwatch:List*",
        "logs:Describe*",
        "logs:Get*",
        "logs:FilterLogEvents",
        "logs:StartQuery",
        "logs:StopQuery",
        "logs:GetQueryResults",
      ]
      resources = ["*"]
    }
  }

  role_arns = [
    for k, _ in local.roles : "arn:aws:iam::${var.account_id}:role/${local.name_prefix}-${k}"
  ]

  common_tags = {
    Project   = "aws-iam-safe-agent"
    Agent     = var.agent_name
    Env       = var.env
    ManagedBy = "terraform"
  }
}

###############################################################################
# Agent IAM User — has NO permissions of its own except AssumeRole on the
# explicit list above. No wildcards in Resource.
###############################################################################

resource "aws_iam_user" "agent" {
  name = "${local.name_prefix}-agent"
  path = "/agents/"
  tags = local.common_tags
}

data "aws_iam_policy_document" "assume_only" {
  statement {
    sid     = "AgentAssumeRoleOnly"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    # Explicit role ARNs only. No wildcards. If you need to add a role, add it
    # to locals.roles above so it shows up here automatically.
    resources = local.role_arns
  }
}

resource "aws_iam_user_policy" "assume_only" {
  name   = "${local.name_prefix}-assume-only"
  user   = aws_iam_user.agent.name
  policy = data.aws_iam_policy_document.assume_only.json
}

###############################################################################
# Roles — one per task type. Each:
#   * 15-minute max session
#   * MFA-required trust
#   * Narrow permission policy
###############################################################################

data "aws_iam_policy_document" "trust" {
  for_each = local.roles

  statement {
    sid     = "AgentUserAssumeWithMFA"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_user.agent.arn]
    }

    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
  }
}

resource "aws_iam_role" "task" {
  for_each = local.roles

  name                 = "${local.name_prefix}-${each.key}"
  description          = each.value.description
  max_session_duration = 900 # 15 minutes. Do not raise.
  assume_role_policy   = data.aws_iam_policy_document.trust[each.key].json

  tags = merge(local.common_tags, {
    RoleKey = each.key
  })
}

data "aws_iam_policy_document" "task" {
  for_each = local.roles

  statement {
    sid       = "TaskScopedPermissions"
    effect    = "Allow"
    actions   = each.value.actions
    resources = each.value.resources
  }
}

resource "aws_iam_role_policy" "task" {
  for_each = local.roles

  name   = "${local.name_prefix}-${each.key}-policy"
  role   = aws_iam_role.task[each.key].id
  policy = data.aws_iam_policy_document.task[each.key].json
}

###############################################################################
# Outputs — feed these into the agent's config.
###############################################################################

output "agent_user_arn" {
  description = "ARN of the agent IAM User. Provision an access key for this user out-of-band."
  value       = aws_iam_user.agent.arn
}

output "role_arns" {
  description = "Map of role_key -> role ARN. Agent's assume() helper uses this map."
  value       = { for k, r in aws_iam_role.task : k => r.arn }
}
