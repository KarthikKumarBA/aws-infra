region             = "ap-south-1"
project            = "karthik-platform"
cluster_name       = "karthik-eks"
kubernetes_version = "1.36"
github_owner       = "KarthikKumarBA"

# Your admin IAM user + the Terraform CI role (from bootstrap output) - both get cluster-admin
cluster_admin_arns = [
  "arn:aws:iam::955151282954:user/terraform-admin",
  "arn:aws:iam::955151282954:role/karthik-platform-github-terraform",
]

# AWS Free plan: only Free-Tier-eligible instance types, on-demand (no spot)
node_instance_types = ["m7i-flex.large"]
node_capacity_type  = "ON_DEMAND"
node_min_size       = 1
node_desired_size   = 1
node_max_size       = 2
