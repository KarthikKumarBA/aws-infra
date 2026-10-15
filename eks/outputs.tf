output "cluster_name" {
  value = module.eks.cluster_name
}

output "region" {
  value = var.region
}

output "ecr_registry" {
  value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "github_deploy_role_arn" {
  value = aws_iam_role.github_deploy.arn
}

output "bedrock_role_arn" {
  value = var.enable_bedrock_irsa ? module.bedrock_irsa[0].iam_role_arn : ""
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "app_repo_github_variables" {
  description = "Set these as GitHub Actions variables in ai-agent-platform and ai-rag-chatbot"
  value = {
    AWS_REGION          = var.region
    EKS_CLUSTER_NAME    = module.eks.cluster_name
    ECR_REGISTRY        = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
    AWS_DEPLOY_ROLE_ARN = aws_iam_role.github_deploy.arn
    BEDROCK_ROLE_ARN    = var.enable_bedrock_irsa ? module.bedrock_irsa[0].iam_role_arn : ""
  }
}
