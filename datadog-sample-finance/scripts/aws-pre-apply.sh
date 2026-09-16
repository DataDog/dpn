#!/usr/bin/env bash
# =============================================================================
# aws-pre-apply.sh — Pre-apply cleanup run automatically by make tf-apply-aws.
#
# Deletes AWS resources that are not tracked in Terraform state but would
# conflict with a fresh apply. Currently handles:
#
#   - /aws/eks/<cluster>/cluster CloudWatch log group
#     The EKS module creates this internally. If a previous apply crashed after
#     the log group was created but before it was written to state, Terraform
#     has no record of it and will fail with ResourceAlreadyExistsException on
#     the next apply. Deleting it here is safe — Terraform recreates it
#     immediately during apply with the correct retention and tags.
#
# Usage: called automatically by make tf-apply-aws. Safe to run manually too.
# =============================================================================
set -euo pipefail

TFVARS="deploy/terraform/aws/staging.tfvars"

# ── Read values from tfvars ───────────────────────────────────────────────────
get_tfvar() {
  grep "^${1}" "$TFVARS" | head -1 | sed 's/.*=[ ]*//' | tr -d '"' | tr -d "'" | tr -d ' '
}

CLUSTER=$(get_tfvar "cluster_name")
REGION=$(get_tfvar "aws_region")
PROFILE=$(get_tfvar "aws_profile")

# Apply defaults if not set in tfvars.
# REGION has no hardcoded default: it must come from staging.tfvars (aws_region).
# This prevents silently deploying to the wrong region on a fresh setup.
CLUSTER="${CLUSTER:-finance-app}"
if [ -z "$REGION" ]; then
  echo "ERROR: aws_region not found in $TFVARS."
  echo "       Add 'aws_region = \"<region>\"' to your staging.tfvars and retry."
  exit 1
fi

PROFILE_ARG=""
if [ -n "$PROFILE" ]; then
  PROFILE_ARG="--profile $PROFILE"
else
  echo "    No aws_profile in tfvars — using default credential chain."
fi

echo "==> Pre-apply cleanup (cluster=$CLUSTER region=$REGION)"

# ── Delete orphaned EKS control-plane log group ───────────────────────────────
# Only the EKS module-internal log group (/aws/eks/<cluster>/cluster) can be
# orphaned — it is created before state is written. The app log group
# (finance_app) is Terraform-tracked from the first resource and cannot get
# into this state.
LOG_GROUP="/aws/eks/${CLUSTER}/cluster"
echo "    Checking for orphaned log group: $LOG_GROUP"

# shellcheck disable=SC2086
if aws logs delete-log-group \
     --log-group-name "$LOG_GROUP" \
     --region "$REGION" \
     $PROFILE_ARG 2>/dev/null; then
  echo "    Deleted orphaned log group (will be recreated by Terraform)."
else
  echo "    Log group not found — nothing to clean."
fi

# ── Ensure admin access entry exists for the current IAM identity ─────────────
# EKS module 21.x uses API auth mode. If the cluster already exists and the
# creator's SSO role isn't in the access entries, kubectl and Terraform both
# fail with "the server has asked for the client to provide credentials".
CLUSTER_EXISTS=$(aws eks describe-cluster --name "$CLUSTER" \
  --region "$REGION" $PROFILE_ARG \
  --query 'cluster.status' --output text 2>/dev/null || true)

if [ "$CLUSTER_EXISTS" = "ACTIVE" ]; then
  CALLER_ARN=$(aws sts get-caller-identity \
    --region "$REGION" $PROFILE_ARG \
    --query 'Arn' --output text 2>/dev/null || true)

  # Extract the base role ARN from the assumed-role session ARN
  # arn:aws:sts::ACCT:assumed-role/ROLE/session -> look up the actual role ARN
  ROLE_NAME=$(echo "$CALLER_ARN" | sed 's|.*assumed-role/||' | cut -d'/' -f1)
  ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" $PROFILE_ARG \
    --query 'Role.Arn' --output text 2>/dev/null || true)

  if [ -n "$ROLE_ARN" ]; then
    echo "    Ensuring admin access entry exists for: $ROLE_ARN"
    aws eks create-access-entry \
      --cluster-name "$CLUSTER" \
      --principal-arn "$ROLE_ARN" \
      --type STANDARD \
      --region "$REGION" $PROFILE_ARG 2>/dev/null || true
    aws eks associate-access-policy \
      --cluster-name "$CLUSTER" \
      --principal-arn "$ROLE_ARN" \
      --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
      --access-scope type=cluster \
      --region "$REGION" $PROFILE_ARG 2>/dev/null && \
      echo "    Admin access entry ensured." || \
      echo "    Access entry already exists or skipped."
  fi
fi

echo "==> Pre-apply cleanup complete."
