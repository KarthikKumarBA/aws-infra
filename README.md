# aws-infra

Shared AWS infrastructure for **ai-agent-platform** and **ai-rag-chatbot**.

| Stack | What it creates | How it runs |
|---|---|---|
| `bootstrap/` | S3 state bucket, GitHub OIDC provider, Terraform CI role | Once, from your laptop (local state) |
| `eks/` | VPC (2 AZs, 1 NAT), EKS + spot node group, EBS CSI, AWS Load Balancer Controller, gp3 StorageClass, app namespaces, ECR repos, GitHub deploy role, Bedrock IRSA role | GitHub Actions (or locally) |

Cost while running: about **$0.20/hour**. Destroy after testing.

## Apply

GitHub → **Actions** → **Terraform** → **Run workflow** → `apply`.

## Destroy

1. In each app repo: **Actions** → **CD** → **Run workflow** → `uninstall`.
2. Here: **Actions** → **Terraform** → **Run workflow** → `destroy`, confirm = `destroy`.

The destroy job removes Helm releases, Ingresses and load balancers first, so the VPC can be deleted.

## Local alternative

```bash
cd eks
terraform init -backend-config="bucket=<state_bucket>" -backend-config="region=ap-south-1"
terraform apply
../scripts/pre-destroy.sh karthik-eks ap-south-1 && terraform destroy
```
