output "region" {
  value = var.region
}

output "state_bucket" {
  description = "GitHub variable TF_STATE_BUCKET"
  value       = aws_s3_bucket.state.bucket
}

output "terraform_role_arn" {
  description = "GitHub variable AWS_TERRAFORM_ROLE_ARN"
  value       = aws_iam_role.terraform.arn
}

output "github_oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}
