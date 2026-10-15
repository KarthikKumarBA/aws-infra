terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.36"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
  }

  # bucket and region are passed at init:
  #   terraform init -backend-config="bucket=<state_bucket>" -backend-config="region=<region>"
  backend "s3" {
    key          = "eks/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
