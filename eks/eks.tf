data "aws_caller_identity" "current" {}

data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

locals {
  deployer_group = "github-deployers"

  # Whoever runs Terraform already gets admin via enable_cluster_creator_admin_permissions
  extra_admins = setsubtract(toset(var.cluster_admin_arns), [data.aws_iam_session_context.current.issuer_arn])

  admin_entries = {
    for arn in local.extra_admins : "admin-${substr(sha1(arn), 0, 8)}" => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  # GitHub deploy role: admin only inside the app namespaces.
  # The Kubernetes group gets native RBAC (rbac.tf) so the role can create Roles/RoleBindings
  # (Kubernetes only lets you grant permissions you hold through RBAC itself).
  deploy_entry = {
    github-deploy = {
      principal_arn     = aws_iam_role.github_deploy.arn
      kubernetes_groups = [local.deployer_group]
      policy_associations = {
        apps = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"
          access_scope = {
            type       = "namespace"
            namespaces = var.app_namespaces
          }
        }
      }
    }
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.37"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.api_public_cidrs

  enable_cluster_creator_admin_permissions = true
  access_entries                           = merge(local.admin_entries, local.deploy_entry)

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent    = true
      before_compute = true
      # Enforce Kubernetes NetworkPolicy (used by the RAG chart)
      configuration_values = jsonencode({ enableNetworkPolicy = "true" })
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types
      capacity_type  = var.node_capacity_type
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size
    }
  }
}
