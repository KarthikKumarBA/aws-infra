variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "project" {
  type    = string
  default = "karthik-platform"
}

variable "cluster_name" {
  type    = string
  default = "karthik-eks"
}

variable "kubernetes_version" {
  description = "Pick one in STANDARD support: aws eks describe-cluster-versions --region <region>"
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "az_count" {
  type    = number
  default = 2
}

variable "node_instance_types" {
  type    = list(string)
  default = ["m7i-flex.large"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND (AWS Free plan allows only Free-Tier types on-demand) or SPOT"
  type        = string
  default     = "ON_DEMAND"
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 2
}

variable "node_desired_size" {
  type    = number
  default = 1
}

variable "api_public_cidrs" {
  description = "Who can reach the Kubernetes API. GitHub-hosted runners use changing IPs, so this stays open; access still needs IAM + EKS access entries."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "cluster_admin_arns" {
  description = "IAM users/roles that get cluster-admin (your admin user and the Terraform CI role)"
  type        = list(string)
  default     = []
}

variable "github_owner" {
  type = string
}

variable "app_repos" {
  description = "Application repositories allowed to deploy (GitHub OIDC, main branch)"
  type        = list(string)
  default     = ["ai-agent-platform", "ai-rag-chatbot"]
}

variable "app_namespaces" {
  description = "One namespace per application repo; the deploy role is admin only inside these"
  type        = list(string)
  default     = ["ai-agent-platform", "ai-rag-chatbot"]
}

variable "rag_namespace" {
  description = "Namespace of the RAG assistant (used for the Bedrock IRSA role)"
  type        = string
  default     = "ai-rag-chatbot"
}

variable "ecr_repositories" {
  type    = list(string)
  default = ["northwind-wiki", "ai-rag-chatbot", "sample-app", "ai-agent"]
}

variable "enable_bedrock_irsa" {
  description = "Create an IAM role so the RAG pod can call Amazon Bedrock without keys"
  type        = bool
  default     = true
}

variable "lbc_chart_version" {
  description = "AWS Load Balancer Controller chart version (null = latest)"
  type        = string
  default     = null
}
