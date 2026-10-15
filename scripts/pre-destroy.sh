#!/usr/bin/env bash
# Removes everything that created AWS load balancers, so 'terraform destroy' can delete the VPC.
# Usage: scripts/pre-destroy.sh <cluster-name> <region>
set -euo pipefail

CLUSTER="${1:?cluster name}"
REGION="${2:?region}"
APP_NAMESPACES="ai-rag-chatbot ai-agent-platform"

if ! aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
  echo "Cluster $CLUSTER not found - nothing to clean up."
  exit 0
fi

aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null

echo "==> Uninstalling application Helm releases"
for ns in $APP_NAMESPACES; do
  for release in $(helm list -n "$ns" -q 2>/dev/null); do
    echo "    helm uninstall $release -n $ns"
    helm uninstall "$release" -n "$ns" --wait --timeout 5m || true
  done
done

echo "==> Deleting all Ingresses"
kubectl delete ingress --all -A --ignore-not-found --timeout=5m || true

echo "==> Deleting all LoadBalancer Services"
kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' |
  while read -r ns name; do
    [ -n "$ns" ] && kubectl delete svc "$name" -n "$ns" --ignore-not-found || true
  done

echo "==> Waiting for the controller to remove the ALBs/NLBs"
for i in $(seq 1 30); do
  remaining=$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
    --resource-type-filters elasticloadbalancing:loadbalancer \
    --tag-filters "Key=elbv2.k8s.aws/cluster,Values=$CLUSTER" \
    --query 'length(ResourceTagMappingList)' --output text)
  if [ "$remaining" = "0" ]; then
    echo "    All load balancers removed."
    exit 0
  fi
  echo "    $remaining load balancer(s) left - waiting ($i/30)"
  sleep 10
done

echo "WARNING: load balancers still exist. Check the EC2 console > Load Balancers before destroying."
exit 1
