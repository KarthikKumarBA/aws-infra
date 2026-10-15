# Optional: lets the RAG pod (service account <rag_namespace>/northwind-rag) call Bedrock without keys
resource "aws_iam_policy" "bedrock" {
  count = var.enable_bedrock_irsa ? 1 : 0
  name  = "${var.cluster_name}-rag-bedrock"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "BedrockInvoke"
      Effect = "Allow"
      Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
      Resource = [
        "arn:aws:bedrock:*::foundation-model/anthropic.*",
        "arn:aws:bedrock:*::foundation-model/amazon.titan-embed-*",
        "arn:aws:bedrock:*:*:inference-profile/*anthropic.*",
      ]
    }]
  })
}

module "bedrock_irsa" {
  count   = var.enable_bedrock_irsa ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.55"

  role_name        = "${var.cluster_name}-rag-bedrock"
  role_policy_arns = { bedrock = aws_iam_policy.bedrock[0].arn }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${var.rag_namespace}:northwind-rag"]
    }
  }
}
