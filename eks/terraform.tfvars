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

node_capacity_type = "SPOT"
node_desired_size  = 2
