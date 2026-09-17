#!/usr/bin/env bash
# =============================================================================
# aws-force-destroy.sh — Destroy all finance-app AWS resources. Called by
# 'make tf-destroy-aws'.
#
# This is intentionally thin: EKS node groups/add-ons/cluster, Secrets Manager
# secrets (recovery_window_in_days = 0), and ECR repos (force_delete = true)
# are all Terraform-managed and already destroy in the correct order and
# without recovery-window/non-empty-repo errors — 'terraform destroy' alone
# handles them. The only thing genuinely outside Terraform's state is the
# frontend NLB's own ENI lifecycle, handled below.
#
# Usage:
#   aws sso login --profile partner
#   make tf-destroy-aws
#   # or directly:
#   bash scripts/aws-force-destroy.sh [profile] [region] [cluster_name] [environment]
#
# Defaults: profile=partner, region=eu-west-1, cluster=finance-app, env=staging
# =============================================================================
set -euo pipefail

# Suppress AWS CLI pager for all calls in this script.
export AWS_PAGER=""

# Parse --yes / -y flag (skip confirmation prompt) before positional args.
AUTO_YES=false
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --yes|-y) AUTO_YES=true ;;
    *) ARGS+=("$arg") ;;
  esac
done
set -- "${ARGS[@]+${ARGS[@]}}"

PROFILE="${1:-partner}"
CLUSTER="${3:-finance-app}"
ENV="${4:-staging}"

# Region: prefer explicit arg ($2), then read from staging.tfvars.
if [ -n "${2:-}" ]; then
  REGION="$2"
elif [ -f "deploy/terraform/aws/staging.tfvars" ]; then
  REGION=$(grep '^aws_region' deploy/terraform/aws/staging.tfvars | sed 's/.*=[ ]*//' | tr -d '"' | tr -d ' ')
  if [ -z "$REGION" ]; then
    echo "ERROR: aws_region not found in deploy/terraform/aws/staging.tfvars."
    echo "       Pass it explicitly: bash scripts/aws-force-destroy.sh $PROFILE <region>"
    exit 1
  fi
else
  echo "ERROR: deploy/terraform/aws/staging.tfvars not found and no region passed as arg."
  echo "       Usage: bash scripts/aws-force-destroy.sh [profile] [region] [cluster] [env]"
  exit 1
fi

export AWS_PROFILE="$PROFILE"
export AWS_DEFAULT_REGION="$REGION"

# ── Confirmation prompt ───────────────────────────────────────────────────────
echo ""
echo "  ┌─────────────────────────────────────────────────────────────────┐"
echo "  │  WARNING: This will permanently delete all finance-app AWS      │"
echo "  │  resources: EKS cluster, VPC, ECR repos, IAM roles, secrets.   │"
echo "  │                                                                 │"
echo "  │  Profile : $PROFILE                                            │"
echo "  │  Region  : $REGION                                             │"
echo "  │  Cluster : $CLUSTER                                            │"
echo "  └─────────────────────────────────────────────────────────────────┘"
echo ""
if [ "$AUTO_YES" = true ]; then
  echo "  (auto-confirmed via --yes flag)"
else
  # Read directly from /dev/tty so the prompt works even when stdin is piped.
  read -r -p "  Type 'yes' to confirm: " CONFIRM </dev/tty
  if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 1
  fi
fi
echo ""

echo "==> Using profile=$PROFILE region=$REGION cluster=$CLUSTER env=$ENV"
echo ""

# ── 0. Release any stray, non-Terraform-managed ELBs/ENIs ───────────────────
# The frontend load balancer is Terraform-managed (aws_lb.frontend, an NLB) and
# must be left for 'terraform destroy' below to remove in correct dependency
# order. We only need to clear workloads first and make sure nothing OTHER
# than that NLB is holding an ENI in the VPC before Terraform tries to delete
# subnets/security groups.
echo "==> [1/2] Releasing stray ELBs/ENIs (excluding the Terraform-managed frontend NLB)..."

# a) Clear finance workloads first (best-effort — may not be reachable if
#    the cluster is already gone).
if kubectl get namespace finance --request-timeout=5s >/dev/null 2>&1; then
  echo "    Deleting finance namespace via kubectl..."
  kubectl delete namespace finance --ignore-not-found --wait=true --timeout=120s 2>/dev/null || true
  kubectl delete storageclass gp3 --ignore-not-found 2>/dev/null || true
  echo "    Namespace deleted."
else
  echo "    kubectl not reachable — skipping namespace cleanup."
fi

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:kubernetes.io/cluster/$CLUSTER,Values=owned" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)

if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  echo "    Found VPC: $VPC_ID"

  # Resolve the Terraform-managed frontend NLB's ARN by its deterministic name
  # so we never delete it here — that's terraform destroy's job.
  FRONTEND_LB_ARN=$(aws elbv2 describe-load-balancers \
    --names "${CLUSTER}-frontend" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)

  echo "    Checking for stray ALB/NLB load balancers in VPC..."
  V2_ELBS=$(aws elbv2 describe-load-balancers \
    --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" \
    --output text 2>/dev/null || true)
  STRAY_FOUND=false
  for ARN in $V2_ELBS; do
    if [ "$ARN" = "$FRONTEND_LB_ARN" ]; then
      continue
    fi
    STRAY_FOUND=true
    echo "    Deleting stray ALB/NLB: $ARN"
    aws elbv2 delete-load-balancer --load-balancer-arn "$ARN" >/dev/null 2>&1 || true
  done
  if [ "$STRAY_FOUND" = false ]; then
    echo "    No stray ALB/NLB found in VPC."
  fi

  # Wait briefly for any stray ELB's ENIs to detach, excluding the frontend
  # NLB's own ENIs (it's still alive on purpose — terraform destroy removes
  # it later, in step 2).
  echo "    Waiting for stray ELB ENIs to release (max 60s)..."
  for i in $(seq 1 12); do
    ENI_COUNT=$(aws ec2 describe-network-interfaces \
      --filters "Name=description,Values=ELB*" "Name=status,Values=in-use" \
      --query "length(NetworkInterfaces[?!contains(Description, '${CLUSTER}-frontend')])" \
      --output text 2>/dev/null || echo 0)
    if [ "$ENI_COUNT" = "0" ] || [ "$ENI_COUNT" = "None" ]; then
      echo "    ENIs released."
      break
    fi
    echo "    $ENI_COUNT stray ELB ENI(s) still attached, waiting 5s... ($((i*5))s elapsed)"
    sleep 5
  done
else
  echo "    VPC not found or already deleted — skipping ELB lookup."
fi
echo ""

# ── 2. Run terraform destroy for everything else ─────────────────────────────
# EKS node groups/add-ons/cluster (module-managed, correct destroy order),
# Secrets Manager secrets (recovery_window_in_days = 0), ECR repos
# (force_delete = true), the frontend NLB, VPC, and IAM are all Terraform
# resources — terraform destroy handles all of them.
echo "==> [2/2] Running terraform destroy..."
cd "$(dirname "$0")/../deploy/terraform/aws"
terraform destroy -var-file="staging.tfvars" -auto-approve

echo ""
echo "✓  Destroy complete."
