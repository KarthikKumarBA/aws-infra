# Creates what the main stack needs before it can run in CI:
#   - S3 bucket for Terraform state (versioned, encrypted, private, native locking)
#   - GitHub OIDC identity provider (no AWS keys stored in GitHub)
#   - IAM role that the aws-infra repo's GitHub Actions assume to run Terraform

terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  state_bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"

  # GitHub OIDC "sub" claim, both formats:
  #   classic: repo:OWNER/REPO:<context>
  #   new:     repo:OWNER@<owner-id>/REPO@<repo-id>:<context>
  infra_repo_subjects = flatten([
    for context in ["ref:refs/heads/main", "pull_request"] : [
      "repo:${var.github_owner}/${var.infra_repo}:${context}",
      "repo:${var.github_owner}@*/${var.infra_repo}@*:${context}",
    ]
  ])
}

# ---------- Terraform state bucket ----------
resource "aws_s3_bucket" "state" {
  bucket        = local.state_bucket
  force_destroy = var.allow_state_bucket_destroy
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

# ---------- GitHub OIDC ----------
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

data "aws_iam_policy_document" "terraform_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Only the aws-infra repo: main branch (apply/destroy) and pull requests (plan)
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.infra_repo_subjects
    }
  }
}

resource "aws_iam_role" "terraform" {
  name                 = "${var.project}-github-terraform"
  assume_role_policy   = data.aws_iam_policy_document.terraform_trust.json
  max_session_duration = 7200
}

# Terraform creates VPC, EKS, IAM... Admin is simplest for a lab; scope it down for production.
resource "aws_iam_role_policy_attachment" "terraform_admin" {
  role       = aws_iam_role.terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
