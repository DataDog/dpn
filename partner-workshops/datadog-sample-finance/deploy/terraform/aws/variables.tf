# =============================================================================
# Finance Sample App — AWS Terraform Variables
# =============================================================================
# Usage:
#   export TF_VAR_datadog_api_key="<your-key>"   # never write this to a file
#   terraform plan -var-file="staging.tfvars"
#
# Do NOT create a terraform.tfvars file containing secrets.
# Keep terraform.tfvars in .gitignore; use environment-specific .tfvars only
# for non-sensitive values (region, cluster_name, environment).
# =============================================================================

variable "aws_profile" {
  description = <<-EOT
    AWS CLI named profile to use for authentication.
    Leave empty (default) to use the default credential chain
    (environment variables, ~/.aws/credentials, instance metadata).

    For AWS SSO:
      1. Configure a profile:  aws configure sso
      2. Log in:               aws sso login --profile <profile>
      3. Set this variable:    aws_profile = "<profile>"  in your .tfvars file
         OR export AWS_PROFILE=<profile> in your shell

    The profile is also forwarded to the EKS token command inside the
    Kubernetes provider so kubectl works without a separate kubeconfig step.
  EOT
  type        = string
  default     = ""
}

variable "aws_region" {
  description = "AWS region to deploy the Finance sample app EKS cluster into."
  type        = string
  default     = "eu-west-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must be a valid AWS region identifier, e.g. eu-west-1."
  }
}

variable "cluster_name" {
  description = "Name of the EKS cluster. Used as a prefix for all related AWS resources."
  type        = string
  default     = "finance-app"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,40}$", var.cluster_name))
    error_message = "cluster_name must be 3-40 lowercase alphanumeric characters or hyphens."
  }
}

variable "environment" {
  description = "Deployment environment (staging, production). Maps to the Datadog DD_ENV tag."
  type        = string
  default     = "staging"

  validation {
    condition     = contains(["development", "staging", "production"], var.environment)
    error_message = "environment must be one of: development, staging, production."
  }
}

variable "dd_site" {
  description = "Datadog site to send telemetry to. Defaults to datadoghq.com (US). Use datadoghq.eu for EU region."
  type        = string
  default     = "datadoghq.com"

  validation {
    condition = contains([
      "datadoghq.com",
      "datadoghq.eu",
      "us3.datadoghq.com",
      "us5.datadoghq.com",
      "ap1.datadoghq.com",
      "ddog-gov.com",
    ], var.dd_site)
    error_message = "dd_site must be a valid Datadog site URL. See https://docs.datadoghq.com/getting_started/site/"
  }
}

variable "datadog_api_key" {
  description = <<-EOT
    Datadog API key used by the Datadog Terraform provider and the Datadog Agent.

    SECURITY: Source this from an environment variable — never write it to a file
    committed to git.

    Preferred method:
      export TF_VAR_datadog_api_key="$(aws secretsmanager get-secret-value \
        --secret-id finance-app/staging/dd-api-key \
        --query SecretString --output text)"

    Alternative: set TF_VAR_datadog_api_key directly in your shell before running
    terraform commands. CI/CD pipelines should inject this from a secret store
    (AWS Secrets Manager, HashiCorp Vault, GitHub Actions Secrets, etc.).

    Docs: https://docs.datadoghq.com/account_management/api-app-keys/
  EOT
  type        = string
  sensitive   = true
  default     = "" # empty default so plan works without provider; populated at apply time
}

variable "datadog_app_key" {
  description = <<-EOT
    Datadog Application KEY VALUE (not the Key ID!) — required by the Datadog
    Terraform provider for creating resources (monitors, dashboards, SLOs).

    WARNING: https://app.datadoghq.com/organization-settings/application-keys
    prominently displays the Key ID in the main list — that is NOT this value.
    Click into the key to reveal the actual key value (a long string starting
    with e.g. "ddapp_"), not the shorter UUID-like Key ID. Using the Key ID
    here causes 401 Unauthorized errors on every apply with no indication of
    what's actually wrong.

    Source from TF_VAR_datadog_app_key in your shell or CI secret store.
    Never commit to version control.

    Docs: https://docs.datadoghq.com/account_management/api-app-keys/#application-keys
  EOT
  type        = string
  sensitive   = true
  default     = "" # empty default; populated at apply time
}

variable "eks_kubernetes_version" {
  description = "Kubernetes version for the EKS cluster. Check AWS EKS supported versions before upgrading."
  type        = string
  default     = "1.30"
}

variable "node_instance_type" {
  description = "EC2 instance type for EKS worker nodes. t3.medium is the minimum recommended for the Finance app stack."
  type        = string
  default     = "t3.medium"
}

variable "node_group_min_size" {
  description = "Minimum number of worker nodes in the EKS node group."
  type        = number
  default     = 2
}

variable "node_group_max_size" {
  description = "Maximum number of worker nodes in the EKS node group. Set higher for production traffic spikes."
  type        = number
  default     = 6
}

variable "node_group_desired_size" {
  description = "Desired number of worker nodes at steady state."
  type        = number
  default     = 3
}

variable "log_retention_days" {
  description = "Number of days to retain CloudWatch logs for the Finance app. Adjust for compliance requirements."
  type        = number
  default     = 30
}

variable "domain_name" {
  description = <<-EOT
    Optional custom domain name for the Finance app (e.g. finance.example.com).
    When set, an ACM certificate is created and validated via DNS for this domain,
    and the NLB HTTPS listener uses it — no browser security warnings.

    Leave empty (default) to use the auto-assigned NLB hostname with the ACM
    certificate for the NLB hostname itself (AWS issues a cert automatically
    when you use AWS-managed certificates with ALB/NLB).

    When using a custom domain AND route53_zone_id (below) is also set,
    Terraform creates both the ACM validation CNAME and an alias record
    pointing domain_name at the NLB — no manual DNS step needed. If you
    manage the domain outside Route 53, leave route53_zone_id empty, add
    the CNAME from the acm_validation_records output yourself, and point
    finance.example.com → <nlb-hostname> manually in your DNS provider.

    Examples:
      domain_name = "finance.example.com"   # custom domain
      domain_name = ""                       # use NLB hostname directly
  EOT
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = <<-EOT
    Route 53 hosted zone ID for domain_name's DNS zone. Required only when
    domain_name is set AND you manage that domain's DNS in Route 53 — it is
    used to create both the ACM DNS validation CNAME record and the alias
    record pointing domain_name at the frontend NLB, automatically.

    If you use another DNS provider, leave this empty, use the
    acm_validation_records output to add the CNAME manually, point
    domain_name at the NLB hostname (frontend_lb_dns_name output) yourself,
    and delete the aws_route53_record.acm_validation / aws_route53_record.frontend
    resources in main.tf.
  EOT
  type        = string
  default     = ""
}
