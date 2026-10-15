#!/usr/bin/env bash
# Bootstrap for the EKS stack - idempotent, no Terraform state needed.
#   create  : S3 state bucket + GitHub OIDC provider + Terraform CI role (adopts existing ones)
#   status  : show what exists
#   destroy : delete all of the above, including every version in the state bucket
#
# Usage: GITHUB_OWNER=KarthikKumarBA scripts/bootstrap.sh create|status|destroy
set -euo pipefail

ACTION="${1:?usage: bootstrap.sh create|status|destroy}"
REGION="${AWS_REGION:-ap-south-1}"
PROJECT="${PROJECT:-karthik-platform}"
GITHUB_OWNER="${GITHUB_OWNER:?set GITHUB_OWNER, for example KarthikKumarBA}"
INFRA_REPO="${INFRA_REPO:-aws-infra}"
CLUSTER_NAME="${CLUSTER_NAME:-karthik-eks}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="${PROJECT}-tfstate-${ACCOUNT_ID}"
ROLE="${PROJECT}-github-terraform"
OIDC_HOST="token.actions.githubusercontent.com"
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"
ADMIN_POLICY="arn:aws:iam::aws:policy/AdministratorAccess"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# AWS CLI on Windows needs a Windows path for file:// arguments
file_uri() {
  if command -v cygpath >/dev/null 2>&1; then echo "file://$(cygpath -w "$1")"; else echo "file://$1"; fi
}

bucket_exists() { aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; }
oidc_exists()   { aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; }
role_exists()   { aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; }

status() {
  echo "Account:       $ACCOUNT_ID"
  echo "Region:        $REGION"
  echo "State bucket:  $BUCKET  -> $(bucket_exists && echo EXISTS || echo missing)"
  echo "OIDC provider: $OIDC_ARN  -> $(oidc_exists && echo EXISTS || echo missing)"
  echo "CI role:       arn:aws:iam::${ACCOUNT_ID}:role/${ROLE}  -> $(role_exists && echo EXISTS || echo missing)"
}

create() {
  echo "==> State bucket"
  if bucket_exists; then
    echo "    $BUCKET already exists"
  elif [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
    echo "    created $BUCKET"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
    echo "    created $BUCKET"
  fi
  aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "$BUCKET" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-tagging --bucket "$BUCKET" \
    --tagging "TagSet=[{Key=Project,Value=$PROJECT},{Key=ManagedBy,Value=bootstrap-script}]"
  echo "    versioning, encryption and public access block set"

  echo "==> GitHub OIDC provider"
  if oidc_exists; then
    echo "    already exists"
  else
    aws iam create-open-id-connect-provider --url "https://$OIDC_HOST" \
      --client-id-list sts.amazonaws.com \
      --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 1c58a3a8518e8759bf075b76b750d4f2df264fcd >/dev/null
    echo "    created"
  fi

  echo "==> Terraform CI role"
  cat > "$TMP_DIR/trust.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "$OIDC_ARN" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "$OIDC_HOST:aud": "sts.amazonaws.com" },
      "StringLike": {
        "$OIDC_HOST:sub": [
          "repo:$GITHUB_OWNER/$INFRA_REPO:ref:refs/heads/main",
          "repo:$GITHUB_OWNER@*/$INFRA_REPO@*:ref:refs/heads/main",
          "repo:$GITHUB_OWNER/$INFRA_REPO:pull_request",
          "repo:$GITHUB_OWNER@*/$INFRA_REPO@*:pull_request"
        ]
      }
    }
  }]
}
JSON
  if role_exists; then
    aws iam update-assume-role-policy --role-name "$ROLE" --policy-document "$(file_uri "$TMP_DIR/trust.json")"
    echo "    already exists - trust policy updated"
  else
    aws iam create-role --role-name "$ROLE" --max-session-duration 7200 \
      --assume-role-policy-document "$(file_uri "$TMP_DIR/trust.json")" \
      --tags "Key=Project,Value=$PROJECT" "Key=ManagedBy,Value=bootstrap-script" >/dev/null
    echo "    created"
  fi
  aws iam attach-role-policy --role-name "$ROLE" --policy-arn "$ADMIN_POLICY"
  echo "    AdministratorAccess attached (lab only - scope down for production)"

  echo
  echo "GitHub variables for aws-infra:"
  echo "  AWS_REGION             = $REGION"
  echo "  TF_STATE_BUCKET        = $BUCKET"
  echo "  AWS_TERRAFORM_ROLE_ARN = arn:aws:iam::${ACCOUNT_ID}:role/${ROLE}"
}

empty_bucket() {
  while true; do
    count=$(aws s3api list-object-versions --bucket "$BUCKET" --max-items 500 \
      --query 'length([Versions[], DeleteMarkers[]][])' --output text 2>/dev/null || echo 0)
    if [ "$count" = "0" ] || [ "$count" = "None" ]; then break; fi
    aws s3api list-object-versions --bucket "$BUCKET" --max-items 500 \
      --query '{Objects: [Versions[].{Key: Key, VersionId: VersionId}, DeleteMarkers[].{Key: Key, VersionId: VersionId}][], Quiet: `true`}' \
      --output json > "$TMP_DIR/delete.json"
    aws s3api delete-objects --bucket "$BUCKET" --delete "$(file_uri "$TMP_DIR/delete.json")" >/dev/null
    echo "    deleted $count object version(s)"
  done
}

destroy() {
  if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
    echo "ERROR: EKS cluster $CLUSTER_NAME still exists. Run the Terraform workflow with action=destroy first."
    exit 1
  fi

  echo "==> State bucket"
  if bucket_exists; then
    empty_bucket
    aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION"
    echo "    deleted $BUCKET"
  else
    echo "    not found"
  fi

  echo "==> Terraform CI role"
  if role_exists; then
    for arn in $(aws iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[].PolicyArn' --output text); do
      aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$arn"
    done
    for name in $(aws iam list-role-policies --role-name "$ROLE" --query 'PolicyNames[]' --output text); do
      aws iam delete-role-policy --role-name "$ROLE" --policy-name "$name"
    done
    aws iam delete-role --role-name "$ROLE"
    echo "    deleted $ROLE"
  else
    echo "    not found"
  fi

  echo "==> GitHub OIDC provider"
  if oidc_exists; then
    aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN"
    echo "    deleted"
  else
    echo "    not found"
  fi

  echo
  echo "Bootstrap removed. Optional: delete the terraform-admin access key and the BOOTSTRAP_* GitHub secrets."
}

case "$ACTION" in
  create)  create; echo; status ;;
  status)  status ;;
  destroy) destroy; echo; status ;;
  *) echo "usage: bootstrap.sh create|status|destroy"; exit 1 ;;
esac
