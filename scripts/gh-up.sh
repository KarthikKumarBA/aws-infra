#!/usr/bin/env bash
# Bring EVERYTHING up from an empty account, in order, via GitHub Actions:
#   Bootstrap apply -> Terraform apply -> ai-rag-chatbot CD deploy -> ai-agent-platform CD deploy
# Stops at the first failure. About 35-40 minutes. Costs start at Terraform apply (~$0.20/hour).
# Usage (Git Bash):  scripts/gh-up.sh
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib-gh.sh

export AWS_PROFILE="${AWS_PROFILE:-admin}"
REGION="${REGION:-ap-south-1}"
CLUSTER="${CLUSTER:-karthik-eks}"

echo "==> Updating ALLOWED_CIDR to your current public IP"
gh variable set ALLOWED_CIDR --body "$(curl -s https://checkip.amazonaws.com)/32" --repo "$OWNER/ai-rag-chatbot" || exit 1

run_and_wait aws-infra         bootstrap.yml -f action=apply &&
run_and_wait aws-infra         terraform.yml -f action=apply &&
run_and_wait ai-rag-chatbot    cd.yml        -f action=deploy &&
run_and_wait ai-agent-platform cd.yml        -f action=deploy || { echo "==> Stopped - fix the failed step and run again"; exit 1; }

echo "==> Connecting kubectl"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"
kubectl get nodes
kubectl get pods -n ai-rag-chatbot
kubectl get pods -n ai-agent-platform
echo "==> Wiki: http://$(kubectl get ingress northwind-wiki -n ai-rag-chatbot -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
echo "==> Everything is up"
