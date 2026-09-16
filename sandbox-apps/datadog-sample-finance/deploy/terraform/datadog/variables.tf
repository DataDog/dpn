# =============================================================================
# Finance Sample App — Datadog Terraform Variables
# =============================================================================
# Usage:
#   export TF_VAR_datadog_api_key="$(aws secretsmanager get-secret-value \
#     --secret-id finance-app/staging/dd-api-key --query SecretString --output text)"
#   export TF_VAR_datadog_app_key="$(aws secretsmanager get-secret-value \
#     --secret-id finance-app/staging/dd-app-key --query SecretString --output text)"
#   terraform plan  -var-file="staging.tfvars"
#   terraform apply -var-file="staging.tfvars"
# =============================================================================

variable "datadog_api_key" {
  description = "Datadog API key. Source from AWS Secrets Manager — never hardcode. Use TF_VAR_datadog_api_key env var."
  type        = string
  sensitive   = true
}

variable "datadog_app_key" {
  description = <<-EOT
    Datadog Application KEY VALUE (not the Key ID!). Required by the Datadog
    provider for write operations. Source from AWS Secrets Manager (EKS) or
    .env (local). Use TF_VAR_datadog_app_key env var.

    WARNING: https://app.datadoghq.com/organization-settings/application-keys
    prominently displays the Key ID in the main list -- that is NOT this value.
    Click into the key to reveal the actual key value (a long string starting
    with e.g. "ddapp_"), not the shorter UUID-like Key ID. Using the Key ID
    here causes 401 Unauthorized errors on every apply with no indication of
    what's actually wrong.
  EOT
  type        = string
  sensitive   = true
}

variable "keycloak_client_secret" {
  description = <<-EOT
    Client secret for the 'finance-gateway' Keycloak client, used by the
    auth-dependent Synthetic API tests (payment_happy_path, balance_check,
    payment_bad_payload) to log in as a test user and obtain a fresh JWT on
    every test run — avoiding the need for a static, expiring bearer token.

    Get it with:
      kubectl get secret app-secrets -n finance \
        -o jsonpath='{.data.keycloak-client-secret}' | base64 -d

    Use TF_VAR_keycloak_client_secret env var — never commit the real value.
    Leave empty to skip creating the login-dependent synthetic test steps'
    expected credentials (tests will fail auth until this is set).
  EOT
  type        = string
  sensitive   = true
  default     = ""
}

variable "datadog_site" {
  description = "Datadog site (e.g. datadoghq.com, datadoghq.eu). Must match the site used by the Agent."
  type        = string
  default     = "datadoghq.com"
}

variable "environment" {
  description = "Deployment environment. Used to scope tags and index filters."
  type        = string
  default     = "staging"

  validation {
    condition     = contains(["development", "staging", "production"], var.environment)
    error_message = "environment must be one of: development, staging, production."
  }
}

variable "cluster_name" {
  description = "EKS cluster name. Used to scope log index filters and dashboard titles."
  type        = string
  default     = "finance-app"
}

variable "log_retention_days" {
  description = "Log retention in days for the finance-app log index."
  type        = number
  default     = 15

  validation {
    condition     = contains([3, 7, 15, 30, 45, 60, 90, 180, 360], var.log_retention_days)
    error_message = "log_retention_days must be a valid Datadog retention value: 3, 7, 15, 30, 45, 60, 90, 180, or 360."
  }
}

variable "synthetic_target_base_url" {
  description = <<-EOT
    Public base URL Datadog Synthetic API tests target (Datadog's public
    testing locations, e.g. aws:eu-west-1, cannot resolve in-cluster
    Kubernetes DNS like gateway-api.finance.svc.cluster.local).

    Set this to the frontend (nginx) LoadBalancer hostname created by
    'make deploy-k8s-eks', e.g.:
      http://<hostname>.elb.amazonaws.com

    Get it with:
      kubectl get svc frontend -n finance \
        -o jsonpath='http://{.status.loadBalancer.ingress[0].hostname}'

    nginx proxies the following paths to the right backend service (see
    deploy/kubernetes/base/services/frontend.yaml):
      /health                              -> gateway-api
      /v1/*                                -> gateway-api (JWT required)
      /internal/accounts                   -> account-service (unauthenticated)
      /internal/transactions               -> transaction-service (unauthenticated, read-only)
      /internal/account-service/health     -> account-service
      /internal/transaction-service/health -> transaction-service
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.synthetic_target_base_url == "" || can(regex("^https?://", var.synthetic_target_base_url))
    error_message = "synthetic_target_base_url must start with http:// or https://, or be left empty."
  }
}
