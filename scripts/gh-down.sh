#!/usr/bin/env bash
# Tear EVERYTHING down, in order, via GitHub Actions:
#   ai-rag-chatbot CD uninstall -> ai-agent-platform CD uninstall -> Terraform destroy -> Bootstrap destroy
# Stops at the first failure (Bootstrap destroy never runs while the cluster exists). About 20 minutes.
# Usage (Git Bash):  scripts/gh-down.sh            full teardown
#                    scripts/gh-down.sh --infra    skip app uninstall (apps already removed)
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib-gh.sh

export AWS_PROFILE="${AWS_PROFILE:-admin}"
REGION="${REGION:-ap-south-1}"

if [ "${1:-}" != "--infra" ]; then
  run_and_wait ai-rag-chatbot    cd.yml -f action=uninstall &&
  run_and_wait ai-agent-platform cd.yml -f action=uninstall || { echo "==> Stopped - fix the failed step and run again"; exit 1; }
fi

run_and_wait aws-infra terraform.yml -f action=destroy -f confirm=destroy &&
run_and_wait aws-infra bootstrap.yml -f action=destroy -f confirm=destroy || {
  echo "==> Stopped - fix the failed step, then run: scripts/gh-down.sh --infra"; exit 1; }

echo "==> Checking for anything billable (every line should be [])"
aws eks list-clusters --region "$REGION" --query clusters
aws elbv2 describe-load-balancers --region "$REGION" --query "LoadBalancers[].LoadBalancerName"
aws ec2 describe-nat-gateways --region "$REGION" --filter Name=state,Values=available --query "NatGateways[].NatGatewayId"
aws ec2 describe-instances --region "$REGION" --filters Name=instance-state-name,Values=running --query "Reservations[].Instances[].InstanceId"
aws ec2 describe-volumes --region "$REGION" --filters Name=status,Values=available --query "Volumes[].VolumeId"
aws ec2 describe-addresses --region "$REGION" --query "Addresses[].PublicIp"
aws s3 ls | grep karthik-platform-tfstate || echo "[] state bucket deleted"
echo "==> Teardown complete"
