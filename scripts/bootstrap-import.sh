#!/usr/bin/env bash
# Adopts bootstrap resources that already exist in AWS into an EMPTY bootstrap state.
# Used when no saved state artifact is found (first pipeline run, or the artifact expired),
# including resources created earlier by the old scripts/bootstrap.sh.
# Run from the bootstrap/ directory after "terraform init".
set -uo pipefail

PROJECT="${PROJECT:-karthik-platform}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="${PROJECT}-tfstate-${ACCOUNT_ID}"
ROLE="${PROJECT}-github-terraform"
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
ADMIN_POLICY="arn:aws:iam::aws:policy/AdministratorAccess"

import() {
  if terraform import -input=false "$1" "$2" >/tmp/import.log 2>&1; then
    echo "  imported   $1"
  else
    echo "  not found  $1 (Terraform will create it)"
  fi
}

echo "==> Looking for existing bootstrap resources in account $ACCOUNT_ID"

if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  echo "State bucket $BUCKET exists"
  import aws_s3_bucket.state "$BUCKET"
  import aws_s3_bucket_versioning.state "$BUCKET"
  import aws_s3_bucket_server_side_encryption_configuration.state "$BUCKET"
  import aws_s3_bucket_public_access_block.state "$BUCKET"
else
  echo "State bucket $BUCKET not found - Terraform will create it"
fi

if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
  echo "GitHub OIDC provider exists"
  import aws_iam_openid_connect_provider.github "$OIDC_ARN"
else
  echo "GitHub OIDC provider not found - Terraform will create it"
fi

if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  echo "Role $ROLE exists"
  import aws_iam_role.terraform "$ROLE"
  if aws iam list-attached-role-policies --role-name "$ROLE" --query "AttachedPolicies[].PolicyArn" --output text | grep -q "$ADMIN_POLICY"; then
    import aws_iam_role_policy_attachment.terraform_admin "$ROLE/$ADMIN_POLICY"
  fi
else
  echo "Role $ROLE not found - Terraform will create it"
fi

echo "==> Import finished"
