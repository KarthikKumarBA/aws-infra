# aws-infra - EKS runbook for ai-agent-platform and ai-rag-chatbot

This repository creates the **shared AWS infrastructure** that both application repositories deploy into.
This document is the **single, ordered guide** for the whole EKS lifecycle - from an empty AWS account to running apps, and back to an empty account - **run from the GitHub web UI** or with **one command** from Git Bash.

| Documentation | Where |
|---|---|
| Run the apps **locally** (Python, Docker Compose, local kind) | `README.md` in **ai-rag-chatbot** and **ai-agent-platform** |
| Run everything on **AWS EKS** | **This file** |

---

## Contents

1. [What runs where](#1-what-runs-where)
2. [Cost](#2-cost)
3. [How to run a workflow from the GitHub UI](#3-how-to-run-a-workflow-from-the-github-ui)
4. [All workflows and the order to run them](#4-all-workflows-and-the-order-to-run-them)
5. [Prerequisites (once)](#5-prerequisites-once)
6. [GitHub settings (once)](#6-github-settings-once)
7. [Bring up: bootstrap and cluster](#7-bring-up-bootstrap-and-cluster)
8. [Deploy the applications](#8-deploy-the-applications)
9. [Use and test on EKS](#9-use-and-test-on-eks)
10. [Deploy a change](#10-deploy-a-change)
11. [Tear down everything (exact order)](#11-tear-down-everything-exact-order)
12. [Next time: bring it back](#12-next-time-bring-it-back)
13. [How the state is stored](#13-how-the-state-is-stored)
14. [Troubleshooting](#14-troubleshooting)
15. [Reference](#15-reference)

---

## 1. What runs where

```
┌──────────────────────────── AWS account 955151282954 (ap-south-1) ────────────────────────────┐
│                                                                                                │
│  aws-infra                                                                                     │
│   ├─ Bootstrap workflow   S3 state bucket · GitHub OIDC provider · Terraform CI role           │
│   │                       (state: GitHub Actions artifact)                                     │
│   └─ Terraform workflow   VPC (2 AZs, 1 NAT) · EKS 1.36 · node group (m7i-flex.large)          │
│                           EBS CSI · AWS Load Balancer Controller · gp3 StorageClass            │
│                           app namespaces · ECR repos · GitHub deploy role · Bedrock IRSA        │
│                           (state: the S3 bucket above)                                         │
│                                                                                                │
│  EKS cluster karthik-eks                                                                       │
│   ├─ namespace ai-rag-chatbot     ← ai-rag-chatbot CD     (wiki + RAG assistant + ALB)          │
│   ├─ namespace ai-agent-platform  ← ai-agent-platform CD  (AI agent + sample app)              │
│   └─ namespace kube-system        ← Terraform             (cluster add-ons)                    │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
```

| Identity | Used by | Can do |
|---|---|---|
| `terraform-admin` (IAM user, access keys) | **Bootstrap** workflow, your laptop | Create/delete the bootstrap resources; cluster admin |
| `karthik-platform-github-terraform` (OIDC role) | **Terraform** workflow (aws-infra main branch / PRs) | Create/delete VPC, EKS, ECR, IAM |
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
| After a full teardown | **$0** - nothing is left in the account |

> Tear down when you finish testing - [section 11](#11-tear-down-everything-exact-order).

---

## 3. How to run a workflow from the GitHub UI

Every step in this guide uses the same clicks:

1. Open the repository on GitHub (for example **https://github.com/KarthikKumarBA/aws-infra**).
2. Click the **Actions** tab (top).
3. In the **left list**, click the workflow name (**Bootstrap**, **Terraform** or **CD**).
4. On the right, click the grey **Run workflow** button.
5. In the panel that opens:
   - **Use workflow from:** `Branch: main`
   - **action:** choose from the dropdown (for example `apply`)
   - **confirm:** only for `destroy` - type `destroy`
6. Click the green **Run workflow** button.
7. After a few seconds a new run appears at the top of the list - click it.
8. Wait until the run shows a green **✓** (a red **✗** means it failed - click the failed job to see the error).
9. Scroll down to the run **Summary** - it shows the plan, the outputs or the app URL.

> A workflow appears in the left list only while its file is on the `main` branch.

---

## 4. All workflows and the order to run them

| Repo | Workflow (left list) | action | confirm | What it does | Time |
|---|---|---|---|---|---|
| aws-infra | **Bootstrap** | `plan` | - | Shows bootstrap changes | 1 min |
| aws-infra | **Bootstrap** | `apply` | - | Creates (or adopts) state bucket, OIDC provider, Terraform role | 1 min |
| aws-infra | **Terraform** | `plan` | - | Shows infrastructure changes | 1-2 min |
| aws-infra | **Terraform** | `apply` | - | Creates / updates VPC, EKS, ECR, IAM | 20 min first time |
| ai-rag-chatbot | **CD** | `deploy` | - | Test → build → push → Helm → ALB → re-index | 8-12 min |
| ai-agent-platform | **CD** | `deploy` | - | Test → build → push → Helm → health check | 5-8 min |
| ai-rag-chatbot | **CD** | `uninstall` | - | Removes the app, its ALB and volumes | 2 min |
| ai-agent-platform | **CD** | `uninstall` | - | Removes the app | 1 min |
| aws-infra | **Terraform** | `destroy` | `destroy` | Deletes VPC, EKS, ECR, IAM | 15 min |
| aws-infra | **Bootstrap** | `destroy` | `destroy` | Deletes state bucket (all versions), OIDC provider, Terraform role | 1 min |
| both app repos | **CI** | automatic on push | - | Tests, image builds, smoke tests (no AWS) | 3-5 min |

**Bring everything up** - UI order, or one command `scripts/gh-up.sh` ([section 12](#12-next-time-bring-it-back)):

```
Bootstrap apply → Terraform apply → CD deploy (ai-rag-chatbot) → CD deploy (ai-agent-platform)
```

**Tear everything down** - UI order, or one command `scripts/gh-down.sh` ([section 11](#11-tear-down-everything-exact-order)):

```
CD uninstall (ai-rag-chatbot) → CD uninstall (ai-agent-platform) → Terraform destroy → Bootstrap destroy
```

Both scripts trigger the same GitHub workflows, wait for each one, and **stop at the first failure** (printing the failed log).

---

## 5. Prerequisites (once)

Commands are for **Git Bash** unless stated otherwise.

### 5.1 Tools

| Tool | Install (PowerShell) | Check (Git Bash) |
|---|---|---|
| AWS CLI v2 | `winget install --id Amazon.AWSCLI -e` | `aws --version` |
| GitHub CLI | `winget install --id GitHub.cli -e` | `gh --version` |
| kubectl | included with Docker Desktop | `kubectl version --client` |
| Helm (optional) | `winget install --id Helm.Helm -e` | `helm version` |
| Terraform (optional, local plans) | `winget install --id Hashicorp.Terraform -e` | `terraform version` |

If a tool works in PowerShell but not in Git Bash:

```powershell
(Get-Command terraform).Source      # PowerShell - shows the full path
```

```bash
# Git Bash - add that folder (C:\ -> /c/, \ -> /), then restart VS Code completely
echo 'export PATH="$PATH:/c/Users/bakar/AppData/Local/Microsoft/WinGet/Packages/Hashicorp.Terraform_Microsoft.Winget.Source_8wekyb3d8bbwe"' >> ~/.bashrc
source ~/.bashrc
```

### 5.2 GitHub CLI login

```bash
gh auth login        # GitHub.com → HTTPS → Yes → Login with a web browser
gh auth status
```

✅ `Logged in to github.com account KarthikKumarBA`

### 5.3 AWS admin user and profile

AWS console (root login): **IAM → Users → Create user** `terraform-admin` → **Attach policies directly** → **AdministratorAccess** → **Create user** → open the user → **Security credentials → Create access key → Command Line Interface (CLI)** → copy both values.

```bash
aws configure --profile admin          # paste the keys; region ap-south-1; output json
export AWS_PROFILE=admin               # run this in every new Git Bash window
aws sts get-caller-identity --query Arn --output text
```

✅ `arn:aws:iam::955151282954:user/terraform-admin`

### 5.4 AWS account limits

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

### 5.5 Scripts must be executable in Git

Files committed from Windows lose the executable bit, and GitHub runners then fail with `Permission denied` (exit 126). Check once (and after adding any new script):

```bash
git ls-files -s scripts/
```

✅ Every line starts with `100755`. If one shows `100644`:

```bash
git update-index --chmod=+x scripts/*.sh
git commit -m "Make scripts executable"
git push origin main
```

---

## 6. GitHub settings (once)

All values are derived from the account ID, so they stay valid every time you destroy and recreate the infrastructure. **Variables and secrets survive a full teardown.**

### 6.1 aws-infra - variables

**UI:** aws-infra → **Settings** → **Secrets and variables** → **Actions** → **Variables** tab → **New repository variable**, add each:

| Name | Value |
|---|---|
| `AWS_REGION` | `ap-south-1` |
| `TF_STATE_BUCKET` | `karthik-platform-tfstate-955151282954` |
| `AWS_TERRAFORM_ROLE_ARN` | `arn:aws:iam::955151282954:role/karthik-platform-github-terraform` |

**CLI:**

```bash
gh variable set AWS_REGION             --body "ap-south-1" --repo KarthikKumarBA/aws-infra
gh variable set TF_STATE_BUCKET        --body "karthik-platform-tfstate-955151282954" --repo KarthikKumarBA/aws-infra
gh variable set AWS_TERRAFORM_ROLE_ARN --body "arn:aws:iam::955151282954:role/karthik-platform-github-terraform" --repo KarthikKumarBA/aws-infra
```

### 6.2 aws-infra - secrets (Bootstrap only)

**UI:** **Settings** → **Secrets and variables** → **Actions** → **Secrets** tab → **New repository secret**:

| Name | Value |
|---|---|
| `BOOTSTRAP_AWS_ACCESS_KEY_ID` | Access key ID of `terraform-admin` |
| `BOOTSTRAP_AWS_SECRET_ACCESS_KEY` | Secret access key of `terraform-admin` |

**CLI** (copied from your `admin` profile, nothing typed by hand):

```bash
gh secret set BOOTSTRAP_AWS_ACCESS_KEY_ID     --body "$(aws configure get aws_access_key_id --profile admin)"     --repo KarthikKumarBA/aws-infra
gh secret set BOOTSTRAP_AWS_SECRET_ACCESS_KEY --body "$(aws configure get aws_secret_access_key --profile admin)" --repo KarthikKumarBA/aws-infra
```

### 6.3 ai-rag-chatbot and ai-agent-platform - variables

**UI:** in **each** app repo → **Settings** → **Secrets and variables** → **Actions** → **Variables** → **New repository variable**:

| Name | Value | Repos |
|---|---|---|
| `AWS_REGION` | `ap-south-1` | both |
| `EKS_CLUSTER_NAME` | `karthik-eks` | both |
| `ECR_REGISTRY` | `955151282954.dkr.ecr.ap-south-1.amazonaws.com` | both |
| `AWS_DEPLOY_ROLE_ARN` | `arn:aws:iam::955151282954:role/karthik-platform-github-deploy` | both |
| `ALLOWED_CIDR` | your public IP + `/32` (find it at https://checkip.amazonaws.com) | ai-rag-chatbot |
| `BEDROCK_ROLE_ARN` | `arn:aws:iam::955151282954:role/karthik-eks-rag-bedrock` (optional) | ai-rag-chatbot |

**CLI:**

```bash
for repo in ai-agent-platform ai-rag-chatbot; do
  gh variable set AWS_REGION          --body "ap-south-1"                                                    --repo KarthikKumarBA/$repo
  gh variable set EKS_CLUSTER_NAME    --body "karthik-eks"                                                   --repo KarthikKumarBA/$repo
  gh variable set ECR_REGISTRY        --body "955151282954.dkr.ecr.ap-south-1.amazonaws.com"                 --repo KarthikKumarBA/$repo
  gh variable set AWS_DEPLOY_ROLE_ARN --body "arn:aws:iam::955151282954:role/karthik-platform-github-deploy" --repo KarthikKumarBA/$repo
done
gh variable set ALLOWED_CIDR     --body "$(curl -s https://checkip.amazonaws.com)/32"            --repo KarthikKumarBA/ai-rag-chatbot
gh variable set BEDROCK_ROLE_ARN --body "arn:aws:iam::955151282954:role/karthik-eks-rag-bedrock" --repo KarthikKumarBA/ai-rag-chatbot
```

### 6.4 ai-rag-chatbot and ai-agent-platform - secrets

**UI:** in each app repo → **Settings** → **Secrets and variables** → **Actions** → **Secrets** → **New repository secret**, values from that project's `.env`:

| Repo | Secrets |
|---|---|
| ai-rag-chatbot | `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `WIKI_API_TOKEN`, `RAG_API_TOKEN` |
| ai-agent-platform | `AGENT_API_TOKEN`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` |

**CLI** (read from each `.env`, nothing typed by hand):

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

### 6.5 Check

```bash
for repo in aws-infra ai-agent-platform ai-rag-chatbot; do
  echo "== $repo"; gh variable list --repo KarthikKumarBA/$repo; gh secret list --repo KarthikKumarBA/$repo
done
```

✅ aws-infra: 3 variables, 2 secrets · ai-agent-platform: 4 variables, 3 secrets · ai-rag-chatbot: 6 variables, 4 secrets.

### 6.6 Cluster settings (`eks/terraform.tfvars`, committed - no secrets)

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

## 7. Bring up: bootstrap and cluster

> Want it all in one go? Use `scripts/gh-up.sh` ([section 12](#12-next-time-bring-it-back)). The steps below are the same thing, one at a time.

### 7.1 Bootstrap plan

**UI:** aws-infra → **Actions** → **Bootstrap** → **Run workflow** → action **`plan`** → **Run workflow**.

✅ Summary shows the bootstrap plan. If the resources already exist and no state is saved: `No saved state - importing existing resources` and **0 to add, 0 to destroy**.

**CLI:** `gh workflow run bootstrap.yml -f action=plan --repo KarthikKumarBA/aws-infra`

### 7.2 Bootstrap apply

**UI:** **Bootstrap** → **Run workflow** → action **`apply`**.

✅ Summary shows `state_bucket`, `terraform_role_arn`. The run page has an artifact **bootstrap-tfstate** at the bottom.

**CLI:** `gh workflow run bootstrap.yml -f action=apply --repo KarthikKumarBA/aws-infra`

### 7.3 Terraform plan

**UI:** **Terraform** → **Run workflow** → action **`plan`**.

✅ Summary: `Plan: ... to add` (or `No changes` if the cluster already exists) and no errors.

**CLI:** `gh workflow run terraform.yml -f action=plan --repo KarthikKumarBA/aws-infra`

### 7.4 Terraform apply

**UI:** **Terraform** → **Run workflow** → action **`apply`**.

✅ `Apply complete!` (about 20 minutes on an empty account). **The cluster starts costing money from here.**

**CLI:** `gh workflow run terraform.yml -f action=apply --repo KarthikKumarBA/aws-infra`

### 7.5 Connect your laptop

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

## 8. Deploy the applications

Deploy **ai-rag-chatbot first** (its ALB takes the longest), then **ai-agent-platform**.

### 8.1 ai-rag-chatbot

Your IP changed? Update it first:

```bash
gh variable set ALLOWED_CIDR --body "$(curl -s https://checkip.amazonaws.com)/32" --repo KarthikKumarBA/ai-rag-chatbot
```

**UI:** **https://github.com/KarthikKumarBA/ai-rag-chatbot** → **Actions** → **CD** → **Run workflow** → action **`deploy`**.

✅ Run summary: `Wiki: http://k8s-sharedap-....elb.amazonaws.com`

**CLI:** `gh workflow run cd.yml -f action=deploy --repo KarthikKumarBA/ai-rag-chatbot`

```bash
kubectl get pods,pvc,ingress -n ai-rag-chatbot
```

✅ `northwind-wiki` and `northwind-rag` `1/1 Running` · 2 PVCs `Bound` · Ingress with an `ADDRESS`.

### 8.2 ai-agent-platform

**UI:** **https://github.com/KarthikKumarBA/ai-agent-platform** → **Actions** → **CD** → **Run workflow** → action **`deploy`**.

✅ The **Smoke test** step prints `{"status":"healthy"}`.

**CLI:** `gh workflow run cd.yml -f action=deploy --repo KarthikKumarBA/ai-agent-platform`

```bash
kubectl get pods -n ai-agent-platform
helm get manifest ai-agent-platform -n ai-agent-platform | grep -c "failureThreshold: 9"
```

✅ `ai-agent` and `sample-app` `1/1 Running`, and `1` (sample-app liveness 9 × 10 s from the chart).

---

## 9. Use and test on EKS

### 9.1 Northwind Wiki + assistant (browser)

```bash
echo "http://$(kubectl get ingress northwind-wiki -n ai-rag-chatbot -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
```

Open that URL from your allowed IP (DNS can take 1-3 minutes the first time).

| Step | Do | ✅ Expected |
|---|---|---|
| 1 | Open the URL | **Sign in** page |
| 2 | Click **Karthik Kumar** | Wiki home |
| 3 | Finance → Budget FY2026 | Opens (admin), marked "not available to the AI assistant" |
| 4 | 💬 `How many days of annual leave do I get?` | 24 days, link to *Annual Leave Policy* |
| 5 | 💬 `and sick leave?` | 12 days |
| 6 | 💬 `What is the payments database password?` | *I don't know based on the available documents.* |
| 7 | 💬 `What is the L5 salary band?` | *I don't know...* |
| 8 | Switch user → **Asha** → Salary Bands 2026 | 🔒 No permission |
| 9 | Switch user → **Vikram** | No 💬 button, no ✏️ Edit |
| 10 | As Karthik: Laptop Setup Guide → Edit → add `Help desk hours are now 08:00 to 20:00 IST.` → Save → wait 10 s → 💬 `What are the help desk hours?` | *08:00 to 20:00 IST* with a source link |

```bash
kubectl logs -n ai-rag-chatbot deploy/northwind-rag -c rag --tail=30
kubectl logs -n ai-rag-chatbot deploy/northwind-wiki --tail=30
```

### 9.2 AI agent + sample app (terminal)

Window 1:

```bash
kubectl port-forward -n ai-agent-platform svc/sample-app 8081:80
```

Window 2:

```bash
kubectl port-forward -n ai-agent-platform svc/ai-agent 8090:80
```

> Every restart or rollback replaces the `sample-app` pod and **breaks window 1's port-forward** - press Ctrl+C there and run it again before the next test. A request through a stale port-forward returns an empty response.

Window 3 - setup and a helper that approves the newest pending incident:

```bash
cd "/d/AI Projects/ai-agent-platform"
TOKEN=$(grep -m1 '^AGENT_API_TOKEN=' .env | cut -d= -f2-)
AUTH="Authorization: Bearer $TOKEN"
approve_latest() {
  ID=$(curl -s -H "$AUTH" http://127.0.0.1:8090/incidents | python -c "import sys,json; d=json.load(sys.stdin); p=[i for i in d if i.get('status')=='pending_approval']; print(p[-1]['id'] if p else '')")
  if [ -z "$ID" ]; then echo "No pending incident"; return; fi
  echo "Approving incident $ID"
  curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
    -d '{"approve": true}' http://127.0.0.1:8090/incidents/$ID/decision | python -m json.tool
}
curl -s http://127.0.0.1:8081/status; echo
curl -s http://127.0.0.1:8090/health; echo
curl -s -o /dev/null -w "No token: %{http_code}\n" http://127.0.0.1:8090/incidents
```

✅ `"healthy":true` · `{"status":"healthy"}` · `No token: 401`.

| # | Scenario | Commands | ✅ Expected |
|---|---|---|---|
| A | Unhealthy → restart (watcher) | `curl -s -X POST http://127.0.0.1:8081/simulate-failure; echo` → `sleep 50` → `curl -s -H "$AUTH" http://127.0.0.1:8090/incidents \| python -m json.tool` → `approve_latest` | `"source": "watcher"`, `restart_deployment` (rule 6); after approve `"executed": true`, `"healthy": true` |
| B | Memory leak → investigate | Restart window 1 → `curl -s -m 5 -X POST http://127.0.0.1:8081/simulate-memory-leak; echo` → `kubectl get pods -n ai-agent-platform -w` until `RESTARTS 1` → Ctrl+C → `curl -s -X POST -H "$AUTH" http://127.0.0.1:8090/incidents \| python -m json.tool` | `OOMKilled`, `"recommended_action": "investigate"` (rule 2) |
| C | Bad release → rollback | `kubectl set env deployment/sample-app -n ai-agent-platform CRASH_ON_STARTUP=true` → `sleep 60` → `curl -s -H "$AUTH" http://127.0.0.1:8090/incidents \| python -m json.tool` → `approve_latest` | Pod `CrashLoopBackOff`, `"action": "rollback"` (rule 3); after approve `from_revision N` → `to_revision N-1`, `CRASH_ON_STARTUP` removed |

> After scenario B the pod keeps `last_termination_reason: OOMKilled`, so a failure right after it gives `investigate` (rule 2 comes first). Run `simulate-recovery`, wait 2 minutes, or start from a fresh pod before scenario A.

Check least privilege and the audit log:

```bash
SA=$(kubectl get deploy ai-agent -n ai-agent-platform -o jsonpath='{.spec.template.spec.serviceAccountName}')
kubectl auth can-i patch deployment/sample-app -n ai-agent-platform --as=system:serviceaccount:ai-agent-platform:$SA
kubectl auth can-i patch deployment/ai-agent   -n ai-agent-platform --as=system:serviceaccount:ai-agent-platform:$SA
kubectl auth can-i get secrets                  -n ai-agent-platform --as=system:serviceaccount:ai-agent-platform:$SA
kubectl auth can-i delete pods                  -n ai-agent-platform --as=system:serviceaccount:ai-agent-platform:$SA
MSYS_NO_PATHCONV=1 kubectl exec -n ai-agent-platform deploy/ai-agent -- tail -n 5 /app/audit/audit.jsonl
```

✅ `yes`, `no`, `no`, `no`, and one audit line per decision. (`MSYS_NO_PATHCONV=1` stops Git Bash rewriting `/app/...` into a Windows path.)

---

## 10. Deploy a change

| Change | Steps |
|---|---|
| App code or Helm chart | Commit and push → **CI** runs automatically → when green: that repo → **Actions** → **CD** → **Run workflow** → `deploy` |
| Infrastructure | Edit `eks/*.tf` or `eks/terraform.tfvars` → push → **Terraform** `plan` → check the summary → **Terraform** `apply` |
| Bootstrap | Edit `bootstrap/*.tf` → push → **Bootstrap** `plan` → **Bootstrap** `apply` |

> A manual `kubectl patch` / `kubectl set env` is undone by the next CD deploy - put permanent changes in the Helm chart. Check what Helm deployed with `helm history <release> -n <namespace>`.

Images are tagged with the Git commit SHA:

```bash
kubectl get deploy -n ai-rag-chatbot -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
kubectl get deploy -n ai-agent-platform -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
```

---

## 11. Tear down everything (exact order)

### 11.1 One command (recommended)

```bash
cd "/d/AI Projects/aws-infra"
export AWS_PROFILE=admin
scripts/gh-down.sh
```

✅ Four `Result: success` lines, seven lines of `[]` (nothing billable left) and `==> Teardown complete`. About 20 minutes.

It runs, waiting for each one and **stopping at the first failure** (printing the failed log):

| Step | Repo | Workflow | action | Removes |
|---|---|---|---|---|
| 1 | ai-rag-chatbot | **CD** | `uninstall` | Wiki, RAG, ALB, EBS volumes |
| 2 | ai-agent-platform | **CD** | `uninstall` | Agent, sample app |
| 3 | aws-infra | **Terraform** | `destroy` (confirm `destroy`) | EKS, VPC, NAT, Elastic IP, ECR, IAM roles |
| 4 | aws-infra | **Bootstrap** | `destroy` (confirm `destroy`) | State bucket (all versions), OIDC provider, Terraform role |

If it stopped at step 3 or 4, fix the cause ([section 14](#14-troubleshooting)) and continue without uninstalling the apps again:

```bash
scripts/gh-down.sh --infra
```

### 11.2 From the GitHub UI

Same four steps, one at a time, waiting for a green ✓ before the next: **ai-rag-chatbot CD `uninstall`** → **ai-agent-platform CD `uninstall`** → **aws-infra Terraform `destroy`** (confirm `destroy`) → **aws-infra Bootstrap `destroy`** (confirm `destroy`).

Built-in safety:

- **Terraform destroy** first runs `scripts/pre-destroy.sh`, which removes Helm releases, Ingresses and load balancers so the VPC can be deleted.
- **Bootstrap destroy** refuses to run while the EKS cluster exists (Terraform needs the state bucket until it has destroyed everything).
- **Never** run Bootstrap destroy after a failed Terraform destroy - fix Terraform first.

### 11.3 Verify nothing billable is left

(`scripts/gh-down.sh` already does this.)

```bash
export AWS_PROFILE=admin
aws eks list-clusters --region ap-south-1 --query clusters
aws elbv2 describe-load-balancers --region ap-south-1 --query "LoadBalancers[].LoadBalancerName"
aws ec2 describe-nat-gateways --region ap-south-1 --filter Name=state,Values=available --query "NatGateways[].NatGatewayId"
aws ec2 describe-instances --region ap-south-1 --filters Name=instance-state-name,Values=running --query "Reservations[].Instances[].InstanceId"
aws ec2 describe-volumes --region ap-south-1 --filters Name=status,Values=available --query "Volumes[].VolumeId"
aws ec2 describe-addresses --region ap-south-1 --query "Addresses[].PublicIp"
aws s3 ls | grep karthik-platform-tfstate || echo "[] state bucket deleted"
```

✅ Every command prints `[]`.

### 11.4 Optional: remove the admin keys

Only when you are done with AWS for a while (you will need a new key to bring it back):

1. AWS console → **IAM** → **Users** → `terraform-admin` → **Security credentials** → access key → **Deactivate** → **Delete**.
2. Remove the GitHub secrets:

```bash
gh secret delete BOOTSTRAP_AWS_ACCESS_KEY_ID --repo KarthikKumarBA/aws-infra
gh secret delete BOOTSTRAP_AWS_SECRET_ACCESS_KEY --repo KarthikKumarBA/aws-infra
```

---

## 12. Next time: bring it back

All GitHub variables and secrets from section 6 are kept.

### 12.1 One command (recommended)

```bash
cd "/d/AI Projects/aws-infra"
export AWS_PROFILE=admin
scripts/gh-up.sh
```

It updates `ALLOWED_CIDR` to your current IP, then runs, stopping at the first failure:

| Step | Repo | Workflow | action | Time |
|---|---|---|---|---|
| 1 | aws-infra | **Bootstrap** | `apply` | 1 min |
| 2 | aws-infra | **Terraform** | `apply` | 20 min |
| 3 | ai-rag-chatbot | **CD** | `deploy` | 10 min |
| 4 | ai-agent-platform | **CD** | `deploy` | 6 min |

✅ Four `Result: success` lines, then the node and all 4 pods `Running`, `==> Wiki: http://k8s-sharedap-...` and `==> Everything is up`. About 35-40 minutes.

### 12.2 From the GitHub UI

**Bootstrap `apply`** → **Terraform `apply`** → **ai-rag-chatbot CD `deploy`** → **ai-agent-platform CD `deploy`**, waiting for ✓ each time. Then `aws eks update-kubeconfig --name karthik-eks --region ap-south-1`.

- Your IP changed? Update `ALLOWED_CIDR` (6.3) before the ai-rag-chatbot deploy (`gh-up.sh` does it for you).
- You deleted the admin keys (11.4)? Create a new access key and repeat 6.2 first.

---

## 13. How the state is stored

| Stack | State location | Locking |
|---|---|---|
| `bootstrap/` | GitHub Actions artifact **bootstrap-tfstate** (kept 90 days) | One run at a time (workflow concurrency group) |
| `eks/` | `s3://karthik-platform-tfstate-955151282954/eks/terraform.tfstate` (versioned, encrypted) | S3 native lock file |

Every **Bootstrap** run:

1. **Restores** the state from the newest non-expired `bootstrap-tfstate` artifact.
2. If none exists (first run, or older than 90 days), **imports** the existing bucket, OIDC provider and role (`scripts/bootstrap-import.sh`) - nothing is created twice.
3. After `apply` or `destroy`, **saves** the new state as a fresh artifact (after a destroy it is empty, so the next `apply` creates everything from scratch).

That is why the state bucket can be deleted at the end: the bootstrap stack never stores its own state in it.

To see the saved state: aws-infra → **Actions** → **Bootstrap** → newest `apply`/`destroy` run → **Artifacts** → **bootstrap-tfstate**.

---

## 14. Troubleshooting

See the error of the latest failed run of a workflow:

```bash
gh run view $(gh run list --repo KarthikKumarBA/aws-infra --workflow terraform.yml --limit 1 --json databaseId --jq '.[0].databaseId') --repo KarthikKumarBA/aws-infra --log-failed | tail -n 60
```

| Symptom | Cause | Fix |
|---|---|---|
| `scripts/...sh: Permission denied`, exit code 126 | Script committed from Windows without the executable bit | Section 5.5 (`git update-index --chmod=+x scripts/*.sh`), push, run again (`scripts/gh-down.sh --infra` for a teardown) |
| `$'\r': command not found` in a script | Windows line endings | `.gitattributes` forces LF; `git add --renormalize . && git commit -m "LF" && git push` |
| **Bootstrap** not in the left list, or old options `status/create/destroy` | New workflow file not on `main` | `git ls-tree --name-only origin/main .github/workflows/`; push `bootstrap.yml` |
| Bootstrap: `InvalidClientTokenId` / `Unable to locate credentials` | `BOOTSTRAP_*` secrets missing or key deleted | Section 6.2 (new access key if needed) |
| Bootstrap import: `not found ... Terraform will create it` for an existing resource | Name differs from `karthik-platform-*` | Check the name in the AWS console; adjust `project` in `bootstrap/terraform.tfvars` |
| Bootstrap destroy: `EKS cluster karthik-eks still exists` | Terraform destroy not done or failed | Fix and finish Terraform destroy first |
| Bootstrap destroy: `DeleteConflict` on the role | Policies attached outside Terraform | `force_detach_policies = true` handles it; re-run destroy |
| Terraform: `Could not assume role with OIDC` | Terraform role missing | Bootstrap `apply` |
| Terraform init: `S3 bucket does not exist` | Bootstrap not applied | Bootstrap `apply` |
| Node group stuck ~30 min, then `not eligible for Free Tier` | AWS Free plan | Free-Tier type on-demand (`m7i-flex.large`) - 5.4 |
| Node group: `MaxSpotInstanceCountExceeded` / `VcpuLimitExceeded` | EC2 quota | On-demand, or Service Quotas → EC2 → request increase |
| CD: `Could not assume role with OIDC` | Deploy role missing (cluster destroyed) | Terraform `apply` |
| CD: `attempting to grant RBAC permissions not currently held` | RBAC escalation prevention | `eks/rbac.tf` must be applied - Terraform `apply` |
| CD: `has no deployed releases` / `another operation is in progress` | A previous install failed | CD `uninstall`, then `deploy` |
| CD: `namespaces "..." not found` | Terraform apply not run | Terraform `apply`; `kubectl get ns` |
| Wiki URL times out | Your IP is not `ALLOWED_CIDR`, or DNS not ready | Compare https://checkip.amazonaws.com with the variable; update; CD `deploy`; wait 1-3 minutes |
| Ingress has no ADDRESS | Load Balancer Controller | `kubectl describe ingress northwind-wiki -n ai-rag-chatbot`; `kubectl logs -n kube-system deploy/aws-load-balancer-controller --tail=50` |
| RAG pod `Pending` | Volume in another AZ than the node, or node full | `kubectl describe pod -n ai-rag-chatbot -l app.kubernetes.io/name=rag`; set `node_desired_size = 2` |
| Agent: empty response from `:8081` | Stale port-forward after a pod replacement | Restart window 1's port-forward |
| Agent: no watcher incident, pod restarted on its own | Liveness probe faster than the watcher | Chart uses liveness 9 × 10 s; CD `deploy` the latest chart (`helm history` shows a new revision) |
| Agent: `investigate` instead of `restart_deployment` | Pod still has `OOMKilled` from the memory-leak test (rule 2 first) | `simulate-recovery`, wait 2 minutes, trigger again |
| `bash: syntax error near unexpected token newline` | `<id>` pasted literally | Use the `approve_latest` helper (9.2) |
| `tail: cannot open 'C:/Program Files/Git/app/...'` | Git Bash path conversion | Prefix with `MSYS_NO_PATHCONV=1` |
| Terraform destroy fails on VPC / subnet / security group | Leftover load balancer or ENI | `export AWS_PROFILE=admin && scripts/pre-destroy.sh karthik-eks ap-south-1`; delete leftovers in the EC2 console; `scripts/gh-down.sh --infra` |
| `gh: please run gh auth login` | GitHub CLI not logged in | `gh auth login` |

---

## 15. Reference

### 15.1 GitHub settings per repository

| Repo | Variables | Secrets |
|---|---|---|
| aws-infra | `AWS_REGION`, `TF_STATE_BUCKET`, `AWS_TERRAFORM_ROLE_ARN` | `BOOTSTRAP_AWS_ACCESS_KEY_ID`, `BOOTSTRAP_AWS_SECRET_ACCESS_KEY` |
| ai-rag-chatbot | `AWS_REGION`, `EKS_CLUSTER_NAME`, `ECR_REGISTRY`, `AWS_DEPLOY_ROLE_ARN`, `ALLOWED_CIDR`, `BEDROCK_ROLE_ARN` | `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `WIKI_API_TOKEN`, `RAG_API_TOKEN` |
| ai-agent-platform | `AWS_REGION`, `EKS_CLUSTER_NAME`, `ECR_REGISTRY`, `AWS_DEPLOY_ROLE_ARN` | `AGENT_API_TOKEN`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` |

### 15.2 What each stack creates

| Stack / file | Resources |
|---|---|
| `bootstrap/main.tf` | S3 state bucket (versioned, encrypted, private), GitHub OIDC provider, Terraform CI role |
| `eks/vpc.tf` | VPC 10.20.0.0/16, 2 private + 2 public subnets, 1 NAT gateway, ELB subnet tags |
| `eks/eks.tf` | EKS cluster, managed node group, add-ons (vpc-cni with NetworkPolicy, coredns, kube-proxy, pod identity, EBS CSI), access entries |
| `eks/addons.tf` | IRSA roles (EBS CSI, Load Balancer Controller), Load Balancer Controller (Helm), `gp3` default StorageClass, app namespaces |
| `eks/rbac.tf` | RoleBinding `github-deployers` → `admin` in each app namespace |
| `eks/ecr.tf` | ECR repos `northwind-wiki`, `ai-rag-chatbot`, `sample-app`, `ai-agent` (scan on push, keep 15 images) |
| `eks/iam-github.tf` | GitHub deploy role (ECR push, `eks:DescribeCluster`) |
| `eks/bedrock.tf` | Bedrock IRSA role for `ai-rag-chatbot/northwind-rag` |

### 15.3 Repository layout

```
aws-infra/
├── bootstrap/                        # Bootstrap stack (state: GitHub Actions artifact)
│   ├── main.tf  variables.tf  outputs.tf  terraform.tfvars
├── eks/                              # Main stack (state: S3)
│   ├── versions.tf providers.tf variables.tf terraform.tfvars
│   ├── vpc.tf eks.tf addons.tf rbac.tf ecr.tf iam-github.tf bedrock.tf outputs.tf
├── scripts/
│   ├── gh-up.sh                      # one command: Bootstrap apply -> Terraform apply -> both CD deploys
│   ├── gh-down.sh                    # one command: both CD uninstalls -> Terraform destroy -> Bootstrap destroy
│   ├── lib-gh.sh                     # run_and_wait helper used by both
│   ├── bootstrap-import.sh           # adopts existing bootstrap resources when no state is saved
│   └── pre-destroy.sh                # removes load balancers before Terraform destroy
├── .gitattributes                    # *.sh with LF line endings
└── .github/workflows/
    ├── bootstrap.yml                 # plan / apply / destroy
    └── terraform.yml                 # plan / apply / destroy
```
