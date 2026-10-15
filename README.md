# aws-infra - EKS runbook for ai-agent-platform and ai-rag-chatbot

This repository creates the **shared AWS infrastructure** that both application repositories deploy into, and this document is the **single, ordered guide** for the whole EKS lifecycle - from an empty AWS account to running apps, and back to an empty account.

> Every step runs from **GitHub Actions** (UI: Actions → workflow → **Run workflow**) and can also be started from Git Bash with `gh workflow run`. Both ways are shown.

| Documentation | Where |
|---|---|
| **Run the apps locally** (Python, Docker Compose, local kind) | `README.md` in **ai-rag-chatbot** and **ai-agent-platform** |
| **Run everything on AWS EKS** | **This file** |

---

## Contents

1. [What runs where](#1-what-runs-where)
2. [Cost](#2-cost)
3. [Workflows and order](#3-workflows-and-order)
4. [Prerequisites (once)](#4-prerequisites-once)
5. [GitHub settings for aws-infra (once)](#5-github-settings-for-aws-infra-once)
6. [Bring up: bootstrap and cluster](#6-bring-up-bootstrap-and-cluster)
7. [GitHub settings for the app repos (once)](#7-github-settings-for-the-app-repos-once)
8. [Deploy the applications](#8-deploy-the-applications)
9. [Use and test on EKS](#9-use-and-test-on-eks)
10. [Deploy a change](#10-deploy-a-change)
11. [Tear down everything (exact order)](#11-tear-down-everything-exact-order)
12. [Next time: bring it back](#12-next-time-bring-it-back)
13. [Troubleshooting](#13-troubleshooting)
14. [Reference](#14-reference)

---

## 1. What runs where

```
┌──────────────────────────── AWS account 955151282954 (ap-south-1) ────────────────────────────┐
│                                                                                                │
│  aws-infra                                                                                     │
│   ├─ Bootstrap workflow   S3 state bucket · GitHub OIDC provider · Terraform CI role           │
│   └─ Terraform workflow   VPC (2 AZs, 1 NAT) · EKS 1.36 · node group (m7i-flex.large)          │
│                           EBS CSI · AWS Load Balancer Controller · gp3 StorageClass            │
│                           app namespaces · ECR repos · GitHub deploy role · Bedrock IRSA        │
│                                                                                                │
│  EKS cluster karthik-eks                                                                       │
│   ├─ namespace ai-rag-chatbot     ← ai-rag-chatbot CD     (wiki + RAG assistant + ALB)          │
│   ├─ namespace ai-agent-platform  ← ai-agent-platform CD  (AI agent + sample app)              │
│   └─ namespace kube-system        ← Terraform             (cluster add-ons)                    │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
```

| Identity | Used by | Can do |
|---|---|---|
| `terraform-admin` (IAM user, access keys) | **Bootstrap** workflow and your laptop | Create/delete the bootstrap resources; cluster admin |
| `karthik-platform-github-terraform` (OIDC role) | **Terraform** workflow (aws-infra, main branch / PRs) | Create/delete VPC, EKS, ECR, IAM |
| `karthik-platform-github-deploy` (OIDC role) | **CD** workflows (both app repos, main branch) | Push to ECR; Kubernetes `admin` **only inside** the two app namespaces |

---

## 2. Cost

| Item | Approx. cost (ap-south-1) |
|---|---|
| EKS control plane | $0.10 / hour |
| NAT gateway | $0.05 / hour + data |
| 1 × m7i-flex.large node (on-demand) | Free Tier eligible / small hourly cost |
| ALB (wiki) | $0.03 / hour |
| EBS gp3 volumes (15 GiB) | a few cents / day |
| **While the cluster exists** | **about $0.20 / hour (~$5 / day)** |
| Bootstrap only (S3 bucket + IAM) | almost free |

> Tear down when you finish testing - [section 11](#11-tear-down-everything-exact-order).

---

## 3. Workflows and order

| Repo | Workflow | Inputs | What it does | Time |
|---|---|---|---|---|
| aws-infra | **Bootstrap** | `status` | Shows whether bucket / OIDC / role exist | 30 s |
| aws-infra | **Bootstrap** | `create` | Creates (or adopts) bucket, OIDC provider, Terraform role | 1 min |
| aws-infra | **Terraform** | `plan` | Shows infrastructure changes | 1-2 min |
| aws-infra | **Terraform** | `apply` | Creates / updates VPC, EKS, ECR, IAM | 20 min first time |
| ai-rag-chatbot | **CD** | `deploy` | Test → build → push → Helm → ALB → re-index | 8-12 min |
| ai-agent-platform | **CD** | `deploy` | Test → build → push → Helm → health check | 5-8 min |
| ai-rag-chatbot | **CD** | `uninstall` | Removes the app, its ALB and volumes | 2 min |
| ai-agent-platform | **CD** | `uninstall` | Removes the app | 1 min |
| aws-infra | **Terraform** | `destroy` + confirm `destroy` | Deletes VPC, EKS, ECR, IAM | 15 min |
| aws-infra | **Bootstrap** | `destroy` + confirm `destroy` | Deletes the state bucket (all versions), OIDC provider, Terraform role | 1 min |
| both app repos | **CI** | automatic on push | Tests, image builds, smoke tests (no AWS) | 3-5 min |

**Bring everything up:**

```
Bootstrap create → Terraform plan → Terraform apply → CD deploy (ai-rag-chatbot) → CD deploy (ai-agent-platform)
```

**Tear everything down:**

```
CD uninstall (ai-rag-chatbot) → CD uninstall (ai-agent-platform) → Terraform destroy → Bootstrap destroy
```

---

## 4. Prerequisites (once)

All commands are for **Git Bash** unless stated otherwise.

### 4.1 Tools

| Tool | Install (PowerShell) | Check (Git Bash) |
|---|---|---|
| AWS CLI v2 | `winget install --id Amazon.AWSCLI -e` | `aws --version` |
| GitHub CLI | `winget install --id GitHub.cli -e` | `gh --version` |
| kubectl | included with Docker Desktop | `kubectl version --client` |
| Helm (optional, for troubleshooting) | `winget install --id Helm.Helm -e` | `helm version` |
| Terraform (optional, for local plans) | `winget install --id Hashicorp.Terraform -e` | `terraform version` |

If a tool works in PowerShell but not in Git Bash:

```powershell
(Get-Command terraform).Source      # PowerShell - shows the full path
```

```bash
# Git Bash - add that folder (C:\ -> /c/, \ -> /), then restart VS Code completely
echo 'export PATH="$PATH:/c/Users/bakar/AppData/Local/Microsoft/WinGet/Packages/Hashicorp.Terraform_Microsoft.Winget.Source_8wekyb3d8bbwe"' >> ~/.bashrc
source ~/.bashrc
```

### 4.2 GitHub CLI login

```bash
gh auth login        # GitHub.com → HTTPS → Yes → Login with a web browser
gh auth status
```

✅ `Logged in to github.com account KarthikKumarBA`

### 4.3 AWS admin user and profile

AWS console (root login): **IAM → Users → Create user** `terraform-admin` → **Attach policies directly** → **AdministratorAccess** → **Create user** → open the user → **Security credentials → Create access key → Command Line Interface (CLI)** → copy both values.

```bash
aws configure --profile admin          # paste the keys; region ap-south-1; output json
export AWS_PROFILE=admin               # run this in every new Git Bash window
aws sts get-caller-identity --query Arn --output text
```

✅ `arn:aws:iam::955151282954:user/terraform-admin`

### 4.4 AWS account limits

| Account | Node type to use |
|---|---|
| **AWS Free plan** | Only Free-Tier types, **on-demand**. This repo uses `m7i-flex.large` (2 vCPU, 8 GiB). |
| Paid plan | Any type; spot is allowed |

```bash
aws ec2 describe-instance-types --region ap-south-1 --filters Name=free-tier-eligible,Values=true \
  --query "InstanceTypes[].[InstanceType,MemoryInfo.SizeInMiB,ProcessorInfo.SupportedArchitectures[0]]" --output table
aws eks describe-cluster-versions --region ap-south-1 \
  --query "clusterVersions[?versionStatus=='STANDARD_SUPPORT'].clusterVersion" --output text
```

---

## 5. GitHub settings for aws-infra (once)

### 5.1 Variables

The bucket name and role ARN are derived from the account ID, so they stay the same every time you recreate them.

```bash
gh variable set AWS_REGION             --body "ap-south-1" --repo KarthikKumarBA/aws-infra
gh variable set TF_STATE_BUCKET        --body "karthik-platform-tfstate-955151282954" --repo KarthikKumarBA/aws-infra
gh variable set AWS_TERRAFORM_ROLE_ARN --body "arn:aws:iam::955151282954:role/karthik-platform-github-terraform" --repo KarthikKumarBA/aws-infra
```

### 5.2 Secrets for the Bootstrap workflow

Copied from your local `admin` profile - nothing typed by hand:

```bash
gh secret set BOOTSTRAP_AWS_ACCESS_KEY_ID     --body "$(aws configure get aws_access_key_id --profile admin)"     --repo KarthikKumarBA/aws-infra
gh secret set BOOTSTRAP_AWS_SECRET_ACCESS_KEY --body "$(aws configure get aws_secret_access_key --profile admin)" --repo KarthikKumarBA/aws-infra
```

### 5.3 Check

```bash
gh variable list --repo KarthikKumarBA/aws-infra
gh secret list   --repo KarthikKumarBA/aws-infra
```

✅ 3 variables, 2 secrets.

### 5.4 Cluster settings (`eks/terraform.tfvars`, committed - no secrets)

```hcl
region             = "ap-south-1"
project            = "karthik-platform"
cluster_name       = "karthik-eks"
kubernetes_version = "1.36"
github_owner       = "KarthikKumarBA"

cluster_admin_arns = [
  "arn:aws:iam::955151282954:user/terraform-admin",
  "arn:aws:iam::955151282954:role/karthik-platform-github-terraform",
]

node_instance_types = ["m7i-flex.large"]
node_capacity_type  = "ON_DEMAND"
node_min_size       = 1
node_desired_size   = 1
node_max_size       = 2
```

---

## 6. Bring up: bootstrap and cluster

### 6.1 Bootstrap create

**UI:** aws-infra → **Actions** → **Bootstrap** → **Run workflow** → action **`create`** → **Run workflow**.

**CLI:**

```bash
gh workflow run bootstrap.yml -f action=create --repo KarthikKumarBA/aws-infra
sleep 10 && gh run watch --repo KarthikKumarBA/aws-infra
```

✅ Summary shows `State bucket ... EXISTS`, `OIDC provider ... EXISTS`, `CI role ... EXISTS`.

### 6.2 Terraform plan

**UI:** **Terraform** → **Run workflow** → action **`plan`**.

**CLI:**

```bash
gh workflow run terraform.yml -f action=plan --repo KarthikKumarBA/aws-infra
sleep 10 && gh run watch --repo KarthikKumarBA/aws-infra
```

✅ Summary: `Plan: ... to add, 0 to change, 0 to destroy` (about 90 resources on an empty account).

### 6.3 Terraform apply

**UI:** **Terraform** → **Run workflow** → action **`apply`**.

**CLI:**

```bash
gh workflow run terraform.yml -f action=apply --repo KarthikKumarBA/aws-infra
sleep 10 && gh run watch --repo KarthikKumarBA/aws-infra
```

✅ `Apply complete!` (about 20 minutes). The cluster starts costing money from here.

### 6.4 Connect your laptop

```bash
export AWS_PROFILE=admin
aws eks update-kubeconfig --name karthik-eks --region ap-south-1
kubectl get nodes
kubectl get ns ai-rag-chatbot ai-agent-platform
kubectl get pods -n kube-system | grep -E "aws-load-balancer|ebs-csi|coredns"
kubectl get storageclass
for ns in ai-rag-chatbot ai-agent-platform; do kubectl get rolebinding github-deployers-admin -n $ns --no-headers; done
```

✅ 1 node `Ready` · both namespaces `Active` · controller, EBS CSI and CoreDNS pods `Running` · `gp3 (default)` · 2 RoleBindings to `ClusterRole/admin`.

| Switch kubectl to | Command |
|---|---|
| EKS | `kubectl config use-context arn:aws:eks:ap-south-1:955151282954:cluster/karthik-eks` |
| Local kind | `kubectl config use-context docker-desktop` |

---

## 7. GitHub settings for the app repos (once)

These values stay the same when you destroy and recreate the infrastructure, so this is needed only once.

### 7.1 Variables

```bash
for repo in ai-agent-platform ai-rag-chatbot; do
  gh variable set AWS_REGION          --body "ap-south-1"                                                  --repo KarthikKumarBA/$repo
  gh variable set EKS_CLUSTER_NAME    --body "karthik-eks"                                                 --repo KarthikKumarBA/$repo
  gh variable set ECR_REGISTRY        --body "955151282954.dkr.ecr.ap-south-1.amazonaws.com"               --repo KarthikKumarBA/$repo
  gh variable set AWS_DEPLOY_ROLE_ARN --body "arn:aws:iam::955151282954:role/karthik-platform-github-deploy" --repo KarthikKumarBA/$repo
done

# Only your IP can open the wiki - re-run when your IP changes, then redeploy
gh variable set ALLOWED_CIDR --body "$(curl -s https://checkip.amazonaws.com)/32" --repo KarthikKumarBA/ai-rag-chatbot

# Optional: Bedrock without keys for the RAG pod
gh variable set BEDROCK_ROLE_ARN --body "arn:aws:iam::955151282954:role/karthik-eks-rag-bedrock" --repo KarthikKumarBA/ai-rag-chatbot
```

### 7.2 Secrets (read from each project's `.env`)

```bash
cd "/d/AI Projects/ai-agent-platform"
for k in AGENT_API_TOKEN OPENAI_API_KEY ANTHROPIC_API_KEY; do
  gh secret set $k --body "$(grep -m1 "^$k=" .env | cut -d= -f2-)" --repo KarthikKumarBA/ai-agent-platform
done

cd "/d/AI Projects/ai-rag-chatbot"
for k in OPENAI_API_KEY ANTHROPIC_API_KEY WIKI_API_TOKEN RAG_API_TOKEN; do
  gh secret set $k --body "$(grep -m1 "^$k=" .env | cut -d= -f2-)" --repo KarthikKumarBA/ai-rag-chatbot
done
```

### 7.3 Check

```bash
gh variable list --repo KarthikKumarBA/ai-agent-platform
gh secret list   --repo KarthikKumarBA/ai-agent-platform
gh variable list --repo KarthikKumarBA/ai-rag-chatbot
gh secret list   --repo KarthikKumarBA/ai-rag-chatbot
```

✅ ai-agent-platform: 4 variables, 3 secrets · ai-rag-chatbot: 6 variables, 4 secrets.

---

## 8. Deploy the applications

Deploy **ai-rag-chatbot first** (its ALB takes the longest), then **ai-agent-platform**.

### 8.1 ai-rag-chatbot

**UI:** ai-rag-chatbot → **Actions** → **CD** → **Run workflow** → action **`deploy`**.

**CLI:**

```bash
gh workflow run cd.yml -f action=deploy --repo KarthikKumarBA/ai-rag-chatbot
sleep 10 && gh run watch --repo KarthikKumarBA/ai-rag-chatbot
```

✅ Run summary: `Wiki: http://k8s-sharedap-....elb.amazonaws.com`

```bash
kubectl get pods,pvc,ingress -n ai-rag-chatbot
```

✅ `northwind-wiki` and `northwind-rag` `1/1 Running` · 2 PVCs `Bound` · Ingress with an `ADDRESS`.

### 8.2 ai-agent-platform

**UI:** ai-agent-platform → **Actions** → **CD** → **Run workflow** → action **`deploy`**.

**CLI:**

```bash
gh workflow run cd.yml -f action=deploy --repo KarthikKumarBA/ai-agent-platform
sleep 10 && gh run watch --repo KarthikKumarBA/ai-agent-platform
```

✅ Smoke test prints `{"status":"healthy"}`.

```bash
kubectl get pods -n ai-agent-platform
```

✅ `ai-agent` and `sample-app` `1/1 Running`.

---

## 9. Use and test on EKS

### 9.1 Northwind Wiki + assistant

1. Open the **Wiki** URL from the CD run summary (from your allowed IP; DNS can take 1-3 minutes the first time).
2. Sign in as **Karthik Kumar**.
3. 💬 `How many days of annual leave do I get?` → *24 days* with a link.
4. 💬 `What is the payments database password?` → *I don't know based on the available documents.*

```bash
kubectl get ingress northwind-wiki -n ai-rag-chatbot -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo
kubectl logs -n ai-rag-chatbot deploy/northwind-rag -c rag --tail=20
```

### 9.2 AI agent + sample app

Window 1:

```bash
kubectl port-forward -n ai-agent-platform svc/sample-app 8081:80
```

Window 2:

```bash
kubectl port-forward -n ai-agent-platform svc/ai-agent 8090:80
```

Window 3:

```bash
TOKEN=$(grep -m1 '^AGENT_API_TOKEN=' "/d/AI Projects/ai-agent-platform/.env" | cut -d= -f2-)
curl -X POST http://127.0.0.1:8081/simulate-failure
sleep 45
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8090/incidents | python -m json.tool
```

✅ An incident with `"source": "watcher"`, `"status": "pending_approval"`, `"action": "restart_deployment"`. Approve it (replace `<id>`):

```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"approve": true}' http://127.0.0.1:8090/incidents/<id>/decision | python -m json.tool
```

✅ `"executed": true` and `"healthy": true`.

---

## 10. Deploy a change

| Change | Steps |
|---|---|
| App code | Commit and push → **CI** runs automatically → when green, run that repo's **CD `deploy`** |
| Infrastructure | Edit `eks/*.tf` or `eks/terraform.tfvars` → push → **Terraform `plan`** → check → **Terraform `apply`** |

Images are tagged with the Git commit SHA:

```bash
kubectl get deploy -n ai-rag-chatbot -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
kubectl get deploy -n ai-agent-platform -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
```

---

## 11. Tear down everything (exact order)

| Step | Repo | Workflow | Inputs | Removes |
|---|---|---|---|---|
| 1 | ai-rag-chatbot | CD | `uninstall` | Wiki, RAG, ALB, EBS volumes |
| 2 | ai-agent-platform | CD | `uninstall` | Agent, sample app |
| 3 | aws-infra | Terraform | `destroy`, confirm `destroy` | EKS, VPC, NAT, ECR, IAM roles |
| 4 | aws-infra | Bootstrap | `destroy`, confirm `destroy` | State bucket (all versions), OIDC provider, Terraform role |

Wait for each run to finish before starting the next one.

**UI:** run each workflow from **Actions → Run workflow** with the inputs in the table.

**CLI:**

```bash
gh workflow run cd.yml -f action=uninstall --repo KarthikKumarBA/ai-rag-chatbot
sleep 10 && gh run watch --repo KarthikKumarBA/ai-rag-chatbot

gh workflow run cd.yml -f action=uninstall --repo KarthikKumarBA/ai-agent-platform
sleep 10 && gh run watch --repo KarthikKumarBA/ai-agent-platform

gh workflow run terraform.yml -f action=destroy -f confirm=destroy --repo KarthikKumarBA/aws-infra
sleep 10 && gh run watch --repo KarthikKumarBA/aws-infra

gh workflow run bootstrap.yml -f action=destroy -f confirm=destroy --repo KarthikKumarBA/aws-infra
sleep 10 && gh run watch --repo KarthikKumarBA/aws-infra
```

Safety built in:

- Terraform `destroy` first runs `scripts/pre-destroy.sh`, which removes Helm releases, Ingresses and load balancers so the VPC can be deleted.
- Bootstrap `destroy` **refuses to run while the EKS cluster still exists** - the state bucket is needed until Terraform has destroyed everything.

### 11.1 Verify nothing billable is left

```bash
export AWS_PROFILE=admin
aws eks list-clusters --region ap-south-1 --query clusters
aws elbv2 describe-load-balancers --region ap-south-1 --query "LoadBalancers[].LoadBalancerName"
aws ec2 describe-nat-gateways --region ap-south-1 --filter Name=state,Values=available --query "NatGateways[].NatGatewayId"
aws ec2 describe-instances --region ap-south-1 --filters Name=instance-state-name,Values=running --query "Reservations[].Instances[].InstanceId"
aws ec2 describe-volumes --region ap-south-1 --filters Name=status,Values=available --query "Volumes[].VolumeId"
aws ec2 describe-addresses --region ap-south-1 --query "Addresses[].PublicIp"
aws s3api head-bucket --bucket karthik-platform-tfstate-955151282954 2>&1 | grep -q "Not Found\|404" && echo "[] state bucket gone"
```

✅ Every command prints `[]`.

### 11.2 Optional: remove the admin keys too

Only when you are completely done with AWS for this project (you'll need new keys to bring it back):

```bash
gh secret delete BOOTSTRAP_AWS_ACCESS_KEY_ID     --repo KarthikKumarBA/aws-infra
gh secret delete BOOTSTRAP_AWS_SECRET_ACCESS_KEY --repo KarthikKumarBA/aws-infra
```

Then AWS console → **IAM → Users → terraform-admin → Security credentials** → **Deactivate** and **Delete** the access key.

---

## 12. Next time: bring it back

All GitHub variables and secrets from sections 5 and 7 are kept. Run:

| Step | Repo | Workflow | Inputs |
|---|---|---|---|
| 1 | aws-infra | Bootstrap | `create` |
| 2 | aws-infra | Terraform | `apply` |
| 3 | ai-rag-chatbot | CD | `deploy` |
| 4 | ai-agent-platform | CD | `deploy` |

```bash
gh workflow run bootstrap.yml -f action=create --repo KarthikKumarBA/aws-infra
sleep 10 && gh run watch --repo KarthikKumarBA/aws-infra
gh workflow run terraform.yml -f action=apply --repo KarthikKumarBA/aws-infra
sleep 10 && gh run watch --repo KarthikKumarBA/aws-infra
gh workflow run cd.yml -f action=deploy --repo KarthikKumarBA/ai-rag-chatbot
sleep 10 && gh run watch --repo KarthikKumarBA/ai-rag-chatbot
gh workflow run cd.yml -f action=deploy --repo KarthikKumarBA/ai-agent-platform
sleep 10 && gh run watch --repo KarthikKumarBA/ai-agent-platform
aws eks update-kubeconfig --name karthik-eks --region ap-south-1
```

If your IP changed: update `ALLOWED_CIDR` (section 7.1) before step 3.
If you deleted the admin keys (11.2): create a new access key and repeat section 5.2 first.

---

## 13. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Bootstrap: `Unable to locate credentials` / `InvalidClientTokenId` | `BOOTSTRAP_*` secrets missing or the key was deleted | Section 5.2 (create a new access key if needed) |
| Bootstrap destroy: `EKS cluster karthik-eks still exists` | Terraform destroy not done | Run Terraform `destroy` first |
| Terraform: `Could not assume role with OIDC` | Terraform role missing or trust policy outdated | Run **Bootstrap `create`** (also refreshes the trust policy) |
| Terraform init: `S3 bucket does not exist` | Bootstrap not created | Run **Bootstrap `create`** |
| Node group stuck ~30 min, then `not eligible for Free Tier` | AWS Free plan | Free-Tier type on-demand (`m7i-flex.large`) - section 4.4 |
| Node group: `MaxSpotInstanceCountExceeded` / `VcpuLimitExceeded` | EC2 quota | On-demand, or Service Quotas → EC2 → request increase |
| CD: `Could not assume role with OIDC` | Deploy role missing (cluster destroyed) | Terraform `apply` |
| CD: `attempting to grant RBAC permissions not currently held` | RBAC escalation prevention | `eks/rbac.tf` must be applied - Terraform `apply` |
| CD: `has no deployed releases` / `another operation is in progress` | A previous install failed | CD `uninstall`, then `deploy` |
| CD: `namespaces "..." not found` | Terraform apply not run | Terraform `apply`; `kubectl get ns` |
| Wiki URL times out | Your IP is not `ALLOWED_CIDR`, or DNS not ready | Compare `curl -s https://checkip.amazonaws.com` with the variable; update and redeploy; wait 1-3 minutes |
| Ingress has no ADDRESS | Load Balancer Controller | `kubectl describe ingress northwind-wiki -n ai-rag-chatbot`; `kubectl logs -n kube-system deploy/aws-load-balancer-controller --tail=50` |
| RAG pod `Pending` | Volume in another AZ than the node, or node full | `kubectl describe pod -n ai-rag-chatbot -l app.kubernetes.io/name=rag`; set `node_desired_size = 2` |
| Terraform destroy fails on VPC / subnet / security group | Leftover load balancer or ENI | `export AWS_PROFILE=admin && scripts/pre-destroy.sh karthik-eks ap-south-1`, delete leftovers in the EC2 console, re-run destroy |
| `gh: To get started with GitHub CLI, please run: gh auth login` | Not logged in | `gh auth login` |
| Node.js / ubuntu-latest deprecation warnings | Runner changes | Workflows use `checkout@v5`, `setup-python@v6`, `ubuntu-24.04` |

---

## 14. Reference

### 14.1 GitHub settings per repository

| Repo | Variables | Secrets |
|---|---|---|
| aws-infra | `AWS_REGION`, `TF_STATE_BUCKET`, `AWS_TERRAFORM_ROLE_ARN` | `BOOTSTRAP_AWS_ACCESS_KEY_ID`, `BOOTSTRAP_AWS_SECRET_ACCESS_KEY` |
| ai-rag-chatbot | `AWS_REGION`, `EKS_CLUSTER_NAME`, `ECR_REGISTRY`, `AWS_DEPLOY_ROLE_ARN`, `ALLOWED_CIDR`, `BEDROCK_ROLE_ARN` | `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `WIKI_API_TOKEN`, `RAG_API_TOKEN` |
| ai-agent-platform | `AWS_REGION`, `EKS_CLUSTER_NAME`, `ECR_REGISTRY`, `AWS_DEPLOY_ROLE_ARN` | `AGENT_API_TOKEN`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` |

### 14.2 What the Terraform stack creates (`eks/`)

| File | Resources |
|---|---|
| `vpc.tf` | VPC 10.20.0.0/16, 2 private + 2 public subnets, 1 NAT gateway, ELB subnet tags |
| `eks.tf` | EKS cluster, managed node group, add-ons (vpc-cni with NetworkPolicy, coredns, kube-proxy, pod identity, EBS CSI), access entries |
| `addons.tf` | IRSA roles (EBS CSI, Load Balancer Controller), Load Balancer Controller (Helm), `gp3` default StorageClass, app namespaces |
| `rbac.tf` | RoleBinding `github-deployers` → `admin` in each app namespace |
| `ecr.tf` | ECR repos `northwind-wiki`, `ai-rag-chatbot`, `sample-app`, `ai-agent` (scan on push, keep 15 images) |
| `iam-github.tf` | GitHub deploy role (ECR push, `eks:DescribeCluster`) |
| `bedrock.tf` | Bedrock IRSA role for `ai-rag-chatbot/northwind-rag` |

State: `s3://karthik-platform-tfstate-955151282954/eks/terraform.tfstate` (versioned, encrypted, S3 native locking).

### 14.3 Run the bootstrap script locally (alternative to the workflow)

```bash
export AWS_PROFILE=admin
cd "/d/AI Projects/aws-infra"
GITHUB_OWNER=KarthikKumarBA scripts/bootstrap.sh status
GITHUB_OWNER=KarthikKumarBA scripts/bootstrap.sh create
GITHUB_OWNER=KarthikKumarBA scripts/bootstrap.sh destroy     # only after Terraform destroy
```

### 14.4 Repository layout

```
aws-infra/
├── eks/                              # Terraform stack (state in S3)
│   ├── versions.tf providers.tf variables.tf terraform.tfvars
│   ├── vpc.tf eks.tf addons.tf rbac.tf ecr.tf iam-github.tf bedrock.tf outputs.tf
├── scripts/
│   ├── bootstrap.sh                  # state bucket + OIDC provider + Terraform role
│   └── pre-destroy.sh                # removes load balancers before Terraform destroy
└── .github/workflows/
    ├── bootstrap.yml                 # status / create / destroy
    └── terraform.yml                 # plan / apply / destroy
```
