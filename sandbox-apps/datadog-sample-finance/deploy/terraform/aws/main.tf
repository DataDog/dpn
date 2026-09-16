# =============================================================================
# Finance Sample App — AWS EKS Deployment
# =============================================================================
# Provisions:
#   - EKS cluster (terraform-aws-modules/eks/aws ~>20.0)
#   - ECR repositories for all six microservices
#   - AWS Secrets Manager secrets for DD_API_KEY and DATADOG_DBM_PASSWORD
#   - IAM role for the Datadog AWS integration (read-only)
#   - CloudWatch log group + Lambda forwarder subscription
#   - Datadog AWS integration resource (commented out — requires DD_API_KEY)
#
# Security note: DD_API_KEY and DBM passwords are NEVER hardcoded here.
# Supply them via AWS Secrets Manager or TF_VAR_datadog_api_key env var.
# Docs: https://docs.datadoghq.com/integrations/amazon_web_services/
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # datadog provider is only needed when uncommenting the Datadog integration
    # resources below (monitors, dashboards, AWS integration link).
    # datadog = {
    #   source  = "DataDog/datadog"
    #   version = "~> 3.0"
    # }
  }

  # ── REMOTE STATE (recommended for teams) ─────────────────────────────────
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "finance-app/aws/terraform.tfstate"
  #   region         = "eu-west-1"
  #   dynamodb_table = "terraform-lock"
  #   encrypt        = true
  # }


}

# =============================================================================
# PROVIDERS
# =============================================================================

provider "aws" {
  region = var.aws_region

  # SSO / named profile support.
  # Set via:  aws_profile = "my-profile"  in your .tfvars
  # OR:       export AWS_PROFILE=my-profile  before running terraform
  # Leave empty to fall back to the default credential chain.
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      Environment = var.environment
      ManagedBy   = "terraform"
      Project     = "finance-sample-app"
    }
  }
}

# The Kubernetes provider is NOT used here — application workloads are deployed
# via `make deploy-k8s` (kubectl manifests in deploy/kubernetes/base/) after
# Terraform provisions the cluster. This avoids the chicken-and-egg problem
# where the K8s provider would try to authenticate to a cluster that doesn't
# exist yet during the first `terraform plan`.
#
# After `terraform apply`, run the kubeconfig_command output to configure kubectl:
#   eval "$(terraform output -raw kubeconfig_command)"
# Then deploy the application:
#   make deploy-k8s


# ── DATADOG PROVIDER ──────────────────────────────────────────────────────────
# The Datadog provider is configured but Datadog resources are individually
# commented out below. Uncomment provider config when ready to enable the
# Datadog AWS integration.
# Docs: https://registry.terraform.io/providers/DataDog/datadog/latest/docs
#
# provider "datadog" {
#   api_key = var.datadog_api_key     # sourced from TF_VAR_datadog_api_key or Secrets Manager
#   api_url = "https://api.${var.dd_site}"
# }
# ─────────────────────────────────────────────────────────────────────────────

# =============================================================================
# DATA SOURCES
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# =============================================================================
# NETWORKING — VPC
# =============================================================================

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = var.environment != "production" # save cost in non-prod
  enable_dns_hostnames = true
  enable_dns_support   = true

  # EKS-required subnet tags
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}

# =============================================================================
# EKS CLUSTER
# =============================================================================
# Docs: https://registry.terraform.io/modules/terraform-aws-modules/eks/aws

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.eks_kubernetes_version

  vpc_id                 = module.vpc.vpc_id
  subnet_ids             = module.vpc.private_subnets
  endpoint_public_access = true

  # Pin the service CIDR so it is known at plan time — Bottlerocket bootstrap
  # user data requires this value to configure the in-cluster DNS resolver.
  # Without it the launch template is created with empty user data and nodes
  # never join the cluster. Must not overlap with the VPC CIDR (10.0.0.0/16).
  service_ipv4_cidr = "172.20.0.0/16"

  eks_managed_node_groups = {
    finance_app = {
      name           = "${var.cluster_name}-ng"
      instance_types = [var.node_instance_type]

      min_size     = var.node_group_min_size
      max_size     = var.node_group_max_size
      desired_size = var.node_group_desired_size

      # Bottlerocket: container-optimised, immutable root FS, no SSH, automatic updates.
      # cluster_service_cidr must match service_ipv4_cidr set on the cluster above so
      # Bottlerocket can write the correct DNS resolver IP into its bootstrap config.
      # Docs: https://docs.aws.amazon.com/eks/latest/userguide/eks-optimized-ami-bottlerocket.html
      ami_type                   = "BOTTLEROCKET_x86_64"
      cluster_service_cidr       = "172.20.0.0/16"
      enable_bootstrap_user_data = true

      # EKS module 21.x lowered the IMDS hop limit default from 2 to 1.
      # Bottlerocket runs kubelet inside a container, so requests to IMDS
      # traverse an extra network hop. Hop limit 1 drops the packet before
      # it reaches kubelet, preventing credential fetch and node registration.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required" # IMDSv2 enforced
        http_put_response_hop_limit = 2
      }

      # SSM Session Manager is the only way to access Bottlerocket nodes (no SSH).
      # AmazonSSMManagedInstanceCore lets the SSM agent register with the cluster.
      iam_role_additional_policies = {
        AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      labels = {
        role        = "finance-app"
        environment = var.environment
      }

      # ── DATADOG NODE GROUP TAGS ───────────────────────────────────────────
      # These tags flow into Datadog host tags via the AWS integration.
      # Docs: https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging/
      tags = {
        "dd:env"     = var.environment
        "dd:service" = "finance-app"
      }
      # ─────────────────────────────────────────────────────────────────────
    }
  }

  # Let the module manage the EKS control-plane log group so there is no
  # duplicate conflict. Retention is set to 30 days to match the app log group.
  create_cloudwatch_log_group            = true
  cloudwatch_log_group_retention_in_days = var.log_retention_days
  cloudwatch_log_group_tags = {
    Application = "finance-app"
  }

  # Cluster addons — 'addons' is the new key name in module ~> 21.0.
  # vpc-cni MUST use before_compute = true so it is installed before the node
  # group is created. Without it there is a deadlock: the node group waits for
  # nodes to be Ready, nodes need vpc-cni to be Ready, vpc-cni waits for the
  # node group to exist. before_compute breaks this by deploying vpc-cni first.
  addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent    = true
      before_compute = true # install before node group to avoid deadlock
    }
    # EBS CSI driver — needed for persistent volumes (PostgreSQL, ActiveMQ data).
    # service_account_role_arn grants the controller pod EC2 permissions via IRSA
    # (IAM Roles for Service Accounts). Without it the controller uses the node
    # role, which has no EBS permissions, and crashes with UnauthorizedOperation.
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = aws_iam_role.ebs_csi_driver.arn
    }
  }

  # Ensure the IAM identity that runs Terraform always has cluster-admin access.
  # Without this, kubectl and Terraform itself cannot authenticate to the cluster
  # after creation (EKS module 21.x uses API auth, not aws-auth ConfigMap).
  enable_cluster_creator_admin_permissions = true

  # ── NODE SECURITY GROUP — only genuinely custom rules ─────────────────
  # SIMPLIFICATION: this used to hand-declare ~13 rules, but 10 of them
  # (self-CoreDNS TCP/UDP, node-to-node ephemeral ports, cluster-to-node 443/
  # kubelet-10250, and the 4443/6443/8443/9443/10251 "webhook" ports used by
  # metrics-server/prometheus-adapter/Karpenter/ALB-controller/NGINX) are
  # EXACT duplicates of rules the terraform-aws-modules/eks/aws module
  # (pinned ~> 21.0) already creates by default — see node_groups.tf's
  # `node_security_group_rules` (always on) and `node_security_group_recommended_rules`
  # (on by default via `node_security_group_enable_recommended_rules = true`,
  # which we don't even need to set since that IS the default). Likewise the
  # cluster-side `ingress_nodes_443` rule (removed below) duplicates the
  # module's own `cluster_security_group_rules.ingress_nodes_443` default.
  # Only 3 rules here are genuinely new and not covered by module defaults:
  # the Datadog admission-controller webhook port, and the two NLB NodePorts.
  # Docs: https://github.com/terraform-aws-modules/terraform-aws-eks (node_groups.tf)
  node_security_group_additional_rules = {
    # ── DATADOG ADMISSION CONTROLLER — LIBRARY INJECTION WEBHOOK ────────
    # The Datadog Cluster Agent's admission controller listens on port 8000
    # and is invoked by the Kubernetes API server (control plane) as a
    # mutating webhook (`datadog.webhook.lib.injection`, path /injectlib) to
    # inject language tracer libraries (Java, Python, Node.js, Go, .NET)
    # into annotated pods. Without this rule the control plane cannot reach
    # the cluster-agent's webhook endpoint on the node; because the webhook
    # has failurePolicy: Ignore, requests fail *silently* (pods still get
    # admitted, but library injection is skipped) rather than erroring out,
    # which makes this misconfiguration easy to miss. Not part of the
    # module's built-in webhook list (only 4443/6443/8443/9443/10251 are).
    # Docs: https://docs.datadoghq.com/containers/cluster_agent/admission_controller/
    ingress_cluster_8000_datadog_admission_webhook = {
      description              = "Cluster API to node 8000/tcp - Datadog admission controller (library injection webhook)"
      protocol                 = "tcp"
      from_port                = 8000
      to_port                  = 8000
      type                     = "ingress"
      source_security_group_id = module.eks.cluster_security_group_id
    }

    # ── Terraform-managed frontend NLB ────────────────────────
    # The NLB (aws_lb.frontend, target_type=instance) delivers traffic
    # directly to each node's ENI on the fixed NodePorts — NLBs have no
    # security group of their own for this target type, so the node SG
    # itself must allow the public internet in on these two ports. See the
    # "FRONTEND LOAD BALANCER" section below for why this replaced the
    # Kubernetes-provisioned Classic ELB.
    ingress_frontend_nlb_http = {
      description = "Public HTTP for frontend dashboard NodePort (Terraform-managed NLB)"
      protocol    = "tcp"
      from_port   = 30080
      to_port     = 30080
      type        = "ingress"
      cidr_blocks = ["0.0.0.0/0"]
    }
    ingress_frontend_nlb_https = {
      description = "Public HTTPS for Keycloak proxy NodePort (Terraform-managed NLB)"
      protocol    = "tcp"
      from_port   = 30443
      to_port     = 30443
      type        = "ingress"
      cidr_blocks = ["0.0.0.0/0"]
    }
    # Only ever reached via aws_lb_listener.frontend_keycloak_acm below
    # (domain_name-gated), but the node SG itself isn't conditional on that
    # — harmless to always allow, matches the pattern of the two rules above.
    ingress_frontend_nlb_keycloak_acm = {
      description = "Public HTTP for Keycloak proxy NodePort, ACM-terminated at the NLB (Terraform-managed NLB)"
      protocol    = "tcp"
      from_port   = 30444
      to_port     = 30444
      type        = "ingress"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  tags = {
    cluster = var.cluster_name
  }
}

# =============================================================================
# ECR REPOSITORIES — one per microservice
# =============================================================================
# Docs: https://docs.aws.amazon.com/AmazonECR/latest/userguide/what-is-ecr.html

locals {
  services = [
    "gateway-api",
    "account-service",
    "transaction-service",
    "fraud-detection",
    "notification-service",
    "batch-processor",
  ]
}

resource "aws_ecr_repository" "services" {
  for_each = toset(local.services)

  name                 = "finance-app/${each.key}"
  image_tag_mutability = "MUTABLE" # use IMMUTABLE in production for deploy traceability
  force_delete         = true      # let terraform destroy remove the repo even with images still in it

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Service = each.key
  }
}

# Lifecycle policy: keep last 10 tagged images, delete untagged after 1 day
resource "aws_ecr_lifecycle_policy" "services" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 10 tagged images per service"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      },
    ]
  })
}

# =============================================================================
# IAM — EBS CSI Driver (IRSA)
# =============================================================================
# The EBS CSI controller needs EC2 permissions (CreateVolume, AttachVolume, etc.)
# to provision PersistentVolumes. IRSA (IAM Roles for Service Accounts) gives the
# controller pod its own scoped IAM role instead of inheriting the broad node role.
# Docs: https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html

data "aws_iam_policy_document" "ebs_csi_driver_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    actions = ["sts:AssumeRoleWithWebIdentity"]
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
  }
}

resource "aws_iam_role" "ebs_csi_driver" {
  name               = "${var.cluster_name}-ebs-csi-driver"
  description        = "IRSA role for the EBS CSI driver controller in cluster ${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_driver_assume_role.json

  tags = {
    Component = "ebs-csi-driver"
  }
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  role       = aws_iam_role.ebs_csi_driver.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# =============================================================================
# AWS SECRETS MANAGER — sensitive credentials
# =============================================================================
# IMPORTANT: values are placeholder strings — never hardcode real secrets here.
# Populate via:
#   aws secretsmanager put-secret-value --secret-id finance-app/<environment>/dd-api-key \
#       --secret-string "your-actual-key"
# Or use AWS Console / CI pipeline secret injection.

resource "aws_secretsmanager_secret" "dd_api_key" {
  name                    = "finance-app/${var.environment}/dd-api-key"
  description             = "Datadog API key for the Finance sample app. Populate manually — never commit to git."
  recovery_window_in_days = 0 # 0 = force-delete immediately; avoids 'scheduled for deletion' error on re-apply

  tags = {
    Purpose = "datadog-integration"
  }
}

resource "aws_secretsmanager_secret_version" "dd_api_key" {
  secret_id     = aws_secretsmanager_secret.dd_api_key.id
  secret_string = "REPLACE_ME" # Replace via CLI or CI — never commit the real key
}

resource "aws_secretsmanager_secret" "dd_app_key" {
  name                    = "finance-app/${var.environment}/dd-app-key"
  description             = "Datadog Application key for the Finance sample app Terraform provider. Populate manually — never commit to git."
  recovery_window_in_days = 0

  tags = {
    Purpose = "datadog-integration"
  }
}

resource "aws_secretsmanager_secret_version" "dd_app_key" {
  secret_id     = aws_secretsmanager_secret.dd_app_key.id
  secret_string = "REPLACE_ME" # Replace via CLI or CI — never commit the real key
}

resource "aws_secretsmanager_secret" "datadog_dbm_password" {
  name                    = "finance-app/${var.environment}/datadog-dbm-password"
  description             = "Password for the read-only Datadog DBM PostgreSQL user. Populate manually."
  recovery_window_in_days = 0 # 0 = force-delete immediately; avoids 'scheduled for deletion' error on re-apply

  tags = {
    Purpose = "datadog-dbm"
  }
}

resource "aws_secretsmanager_secret_version" "datadog_dbm_password" {
  secret_id     = aws_secretsmanager_secret.datadog_dbm_password.id
  secret_string = "REPLACE_ME" # Replace via CLI or CI — never commit the real password
}

# =============================================================================
# IAM — Datadog AWS Integration role (read-only)
# =============================================================================
# Docs: https://docs.datadoghq.com/integrations/amazon_web_services/
#
# This role is assumed by Datadog's AWS account to collect CloudWatch metrics,
# EC2/EKS resource metadata, and forward events.
# The ExternalId prevents confused-deputy attacks.

locals {
  # Datadog's AWS account ID — do not change
  datadog_aws_account_id = "464622532012"
  # Generate a unique external ID per integration; store in Secrets Manager for audit
  # In practice, retrieve this from Datadog's AWS integration page before applying
  datadog_external_id = "finance-app-${var.environment}-REPLACE_WITH_DD_EXTERNAL_ID"
}

data "aws_iam_policy_document" "datadog_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${local.datadog_aws_account_id}:root"]
    }
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [local.datadog_external_id]
    }
  }
}

resource "aws_iam_role" "datadog_integration" {
  name               = "DatadogIntegration-${var.environment}"
  description        = "Read-only role assumed by Datadog for AWS integration metric collection"
  assume_role_policy = data.aws_iam_policy_document.datadog_assume_role.json

  tags = {
    Purpose = "datadog-aws-integration"
  }
}

# Attach Datadog's recommended AWS managed policy for metric collection
resource "aws_iam_role_policy_attachment" "datadog_core" {
  role       = aws_iam_role.datadog_integration.name
  policy_arn = "arn:aws:iam::aws:policy/SecurityAudit"
}

# Additional permissions required by the Datadog AWS integration
data "aws_iam_policy_document" "datadog_additional" {
  statement {
    sid    = "DatadogMetricsCollection"
    effect = "Allow"
    actions = [
      "apigateway:GET",
      "autoscaling:Describe*",
      "cloudfront:GetDistributionConfig",
      "cloudfront:ListDistributions",
      "cloudtrail:DescribeTrails",
      "cloudtrail:GetTrailStatus",
      "cloudwatch:Describe*",
      "cloudwatch:Get*",
      "cloudwatch:List*",
      "codedeploy:List*",
      "codedeploy:BatchGet*",
      "directconnect:Describe*",
      "dynamodb:List*",
      "dynamodb:Describe*",
      "ec2:Describe*",
      "ecs:Describe*",
      "ecs:List*",
      "eks:Describe*",
      "eks:List*",
      "elasticache:Describe*",
      "elasticache:List*",
      "elasticfilesystem:DescribeFileSystems",
      "elasticloadbalancing:Describe*",
      "kinesis:List*",
      "kinesis:Describe*",
      "lambda:GetPolicy",
      "lambda:List*",
      "logs:DeleteSubscriptionFilter",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:DescribeSubscriptionFilters",
      "logs:FilterLogEvents",
      "logs:PutSubscriptionFilter",
      "logs:TestMetricFilter",
      "rds:Describe*",
      "rds:List*",
      "redshift:Describe*",
      "route53:List*",
      "s3:GetBucketLogging",
      "s3:GetBucketNotification",
      "s3:GetBucketTagging",
      "s3:ListAllMyBuckets",
      "s3:PutBucketNotification",
      "ses:Get*",
      "sns:List*",
      "sns:Publish",
      "sqs:ListQueues",
      "support:*",
      "tag:GetResources",
      "tag:GetTagKeys",
      "tag:GetTagValues",
      "xray:BatchGetTraces",
      "xray:GetTraceSummaries",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "datadog_additional" {
  name        = "DatadogAdditionalPermissions-${var.environment}"
  description = "Additional permissions required by Datadog AWS integration"
  policy      = data.aws_iam_policy_document.datadog_additional.json
}

resource "aws_iam_role_policy_attachment" "datadog_additional" {
  role       = aws_iam_role.datadog_integration.name
  policy_arn = aws_iam_policy.datadog_additional.arn
}

# =============================================================================
# CLOUDWATCH LOG GROUP + LAMBDA FORWARDER SUBSCRIPTION
# =============================================================================
# The Datadog Lambda Forwarder ships CloudWatch logs to Datadog Log Management.
# Deploy the forwarder via the Datadog CloudFormation stack first, then
# reference the ARN here.
# Docs: https://docs.datadoghq.com/logs/guide/forwarder/

resource "aws_cloudwatch_log_group" "finance_app" {
  name              = "/aws/eks/${var.cluster_name}/application"
  retention_in_days = var.log_retention_days

  tags = {
    Application = "finance-app"
  }
}

# =============================================================================
# ACM CERTIFICATE — HTTPS for the Finance frontend NLB
# =============================================================================
# When domain_name is set, requests a publicly trusted TLS certificate from
# AWS Certificate Manager (ACM) and validates it via DNS.
#
# The NLB LoadBalancer service (deploy/kubernetes/base/services/frontend.yaml)
# is annotated in the EKS Kustomize overlay to use this certificate ARN,
# enabling HTTPS on port 443 without browser security warnings.
#
# With this in place:
#   - Browser → NLB :443 (HTTPS, ACM cert) → nginx :80 (HTTP, in-cluster)
#   - nginx sets X-Forwarded-Proto: https → Keycloak issues Secure cookies
#   - No self-signed certificate needed on EKS (self-signed is local-only)
#
# If domain_name is empty, the certificate resource is not created and the
# NLB uses HTTP only — in that case set KEYCLOAK_PUBLIC_URL to the http://
# NLB hostname and use the self-signed cert workaround documented in
# INSTRUMENTATION.md.
#
# Docs: https://docs.aws.amazon.com/acm/latest/userguide/gs-acm-request-public.html
# =============================================================================

resource "aws_acm_certificate" "frontend" {
  count = var.domain_name != "" ? 1 : 0

  domain_name       = var.domain_name
  validation_method = "DNS"

  # subject_alternative_names covers the www. subdomain if needed.
  subject_alternative_names = [
    "www.${var.domain_name}",
  ]

  lifecycle {
    # ACM certificates cannot be deleted while in use by a load balancer.
    # create_before_destroy ensures the new cert is attached before the old one
    # is deleted during a certificate replacement (e.g. domain change).
    create_before_destroy = true
  }

  tags = {
    Name        = "${var.cluster_name}-frontend-cert"
    Environment = var.environment
  }
}

# DNS validation records — add these CNAME records to your DNS provider.
# Terraform outputs them as acm_validation_records for easy copy-paste.
# The certificate remains in PENDING_VALIDATION until the CNAMEs are added.
resource "aws_route53_record" "acm_validation" {
  # Only created if domain_name is set AND you manage that zone in Route 53
  # (route53_zone_id set too). BUG FIX: this used to key off domain_name
  # alone, so setting domain_name with an external DNS provider (Route 53
  # zone not in this account) failed plan/apply with "zone_id must not be
  # empty" instead of cleanly skipping this resource. If you use another
  # DNS provider, leave route53_zone_id empty and use the
  # acm_validation_records output to add the CNAMEs manually — see
  # README.md's "Optional: custom domain + trusted ACM certificate".
  for_each = var.domain_name != "" && var.route53_zone_id != "" ? {
    for dvo in aws_acm_certificate.frontend[0].domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}

  allow_overwrite = true
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]

  # NOTE: this must never be a literal empty string — the AWS provider
  # rejects an empty zone_id during `terraform plan`/`validate` even when
  # for_each evaluates to zero instances. The fallback placeholder below is
  # inert: it's only ever assigned to an instance when for_each is
  # non-empty, i.e. when route53_zone_id is actually set.
  zone_id = var.route53_zone_id != "" ? var.route53_zone_id : "unused-no-custom-domain"
}

resource "aws_acm_certificate_validation" "frontend" {
  count = var.domain_name != "" ? 1 : 0

  certificate_arn         = aws_acm_certificate.frontend[0].arn
  validation_record_fqdns = [for record in aws_route53_record.acm_validation : record.fqdn]

  timeouts {
    create = "10m"
  }
}

# Points domain_name itself at the NLB. The ACM validation CNAME above only
# proves domain ownership to AWS — it does not make the domain resolve to
# anything. Without this record, the certificate is valid but
# https://<domain_name> has nowhere to go. An alias record (not a CNAME) is
# used since Route 53 aliases work at the zone apex and don't incur a
# lookup charge, unlike a CNAME to the NLB's own DNS name.
resource "aws_route53_record" "frontend" {
  count = var.domain_name != "" && var.route53_zone_id != "" ? 1 : 0

  zone_id = var.route53_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.frontend.dns_name
    zone_id                = aws_lb.frontend.zone_id
    evaluate_target_health = true
  }
}

# =============================================================================
# FRONTEND LOAD BALANCER — Terraform-managed NLB (not Kubernetes-provisioned)
# =============================================================================
# BUG FIX / DESIGN CHANGE: the frontend Service used to be `type: LoadBalancer`,
# which lets Kubernetes' own cloud-controller-manager dynamically create a
# Classic ELB (+ its own security group) in AWS. Neither of those is tracked
# in Terraform state at all — they are pure side effects of a Service object.
# If the EKS cluster is ever deleted before that Service is cleaned up (races
# during `make tf-destroy-aws`, or simply deleting the cluster first), the
# controller that would release the ELB no longer exists, and the ELB + its
# security group become permanently orphaned. In practice this blocked VPC/
# subnet deletion with DependencyViolation errors that `terraform destroy`
# could not resolve — the orphaned ELB and SG had to be found and deleted
# manually via the AWS CLI before the destroy could complete.
#
# Fix: the frontend Service stays `type: NodePort` on EKS (same as local —
# see scripts/generate-eks-kustomization.sh, which no longer patches it to
# LoadBalancer), on its existing FIXED node ports (30080 HTTP, 30443 HTTPS —
# see deploy/kubernetes/base/services/frontend.yaml). Terraform owns the
# load balancer directly instead: an NLB targeting those node ports across
# every instance in the EKS managed node group's Auto Scaling Group.
#
# Because this LB is now a first-class Terraform resource with the EKS
# cluster/node group as an implicit dependency, `terraform destroy` always
# tears it down in the correct order automatically — there is no longer any
# AWS resource in this path that Kubernetes creates behind Terraform's back.
# As a bonus, the LB's DNS name is now stable across app redeploys (it only
# changes if this aws_lb resource itself is replaced), instead of changing
# every time the Kubernetes Service object happened to be recreated.
# =============================================================================

resource "aws_lb" "frontend" {
  name               = "${var.cluster_name}-frontend"
  internal           = false
  load_balancer_type = "network"
  subnets            = module.vpc.public_subnets

  tags = {
    Name = "${var.cluster_name}-frontend"
  }
}

# Backs the nginx dashboard + API proxy (nodePort 30080, see frontend.yaml).
resource "aws_lb_target_group" "frontend_http" {
  name        = "${var.cluster_name}-fe-http"
  port        = 30080
  protocol    = "TCP"
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"

  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 10
  }

  tags = {
    Name = "${var.cluster_name}-fe-http"
  }
}

# Backs the self-signed Keycloak HTTPS passthrough (nodePort 30443).
resource "aws_lb_target_group" "frontend_https" {
  name        = "${var.cluster_name}-fe-https"
  port        = 30443
  protocol    = "TCP"
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"

  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 10
  }

  tags = {
    Name = "${var.cluster_name}-fe-https"
  }
}

# Backs the plain-HTTP Keycloak proxy (nodePort 30444) that only exists to
# be fronted by a TLS listener using a real ACM cert — see
# aws_lb_listener.frontend_keycloak_acm below. Only useful when domain_name
# is set, but harmless to always create (mirrors frontend_http/frontend_https
# above, which are also unconditional).
resource "aws_lb_target_group" "frontend_keycloak_acm" {
  name        = "${var.cluster_name}-fe-kc-acm"
  port        = 30444
  protocol    = "TCP"
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"

  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 10
  }

  tags = {
    Name = "${var.cluster_name}-fe-kc-acm"
  }
}

# Plain HTTP — always present, matches local's http://localhost:30080.
resource "aws_lb_listener" "frontend_http" {
  load_balancer_arn = aws_lb.frontend.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend_http.arn
  }
}

# HTTPS with a publicly-trusted ACM cert — only when domain_name is set.
# The NLB terminates TLS here and forwards plain HTTP to nginx on :30080
# (nginx sets X-Forwarded-Proto: https so Keycloak still issues Secure
# cookies correctly). Without a domain_name, use http:// on port 80, or the
# self-signed :8443 passthrough below.
resource "aws_lb_listener" "frontend_https_acm" {
  count = var.domain_name != "" ? 1 : 0

  load_balancer_arn = aws_lb.frontend.arn
  port              = 443
  protocol          = "TLS"
  certificate_arn   = aws_acm_certificate_validation.frontend[0].certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend_http.arn
  }
}

# Self-signed Keycloak HTTPS passthrough — always present, matches local's
# https://localhost:30443 (accept the browser security warning once).
resource "aws_lb_listener" "frontend_keycloak" {
  load_balancer_arn = aws_lb.frontend.arn
  port              = 8443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend_https.arn
  }
}

# Keycloak, but with a publicly-trusted ACM cert instead of the self-signed
# one above — only when domain_name is set. The NLB terminates TLS here and
# forwards plain HTTP to nginx on :30444 (a dedicated port separate from the
# dashboard's own :30080/:443, since Keycloak needs its own origin — see
# deploy/kubernetes/base/services/frontend.yaml's routing table for why a
# sub-path proxy under the dashboard's origin doesn't work: Keycloak
# generates unprefixed absolute URLs in its OIDC discovery document, so a
# reverse proxy under e.g. /auth/ would need KC_HTTP_RELATIVE_PATH set,
# which would also affect the local/self-signed paths — not worth the risk
# for what a second listener on a second port solves cleanly). Port 9443
# was picked to avoid colliding with the self-signed :8443 listener, so
# both can coexist — a partner without a domain still gets working
# self-signed HTTPS, and setting domain_name upgrades Keycloak to a trusted
# cert too without disturbing the existing path.
resource "aws_lb_listener" "frontend_keycloak_acm" {
  count = var.domain_name != "" ? 1 : 0

  load_balancer_arn = aws_lb.frontend.arn
  port              = 9443
  protocol          = "TLS"
  certificate_arn   = aws_acm_certificate_validation.frontend[0].certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend_keycloak_acm.arn
  }
}

# Automatically registers/deregisters every node in the managed node group's
# ASG as it scales — no per-instance Terraform resources needed.
#
# NOTE: for_each is keyed by module.eks.eks_managed_node_groups (a map whose
# keys come straight from this file's own `eks_managed_node_groups = { finance_app = ... }`
# block, so they're known at plan time even on a from-scratch apply). The ASG
# name itself (each.value.node_group_autoscaling_group_names[0]) is only known
# after apply, but that's fine for a resource attribute — only for_each *keys*
# must be statically known. Keying on the flattened list of ASG names directly
# (eks_managed_node_groups_autoscaling_group_names) fails plan on a brand new
# cluster because that whole list is unknown until apply.
resource "aws_autoscaling_attachment" "frontend_http" {
  for_each               = module.eks.eks_managed_node_groups
  autoscaling_group_name = each.value.node_group_autoscaling_group_names[0]
  lb_target_group_arn    = aws_lb_target_group.frontend_http.arn
}

resource "aws_autoscaling_attachment" "frontend_https" {
  for_each               = module.eks.eks_managed_node_groups
  autoscaling_group_name = each.value.node_group_autoscaling_group_names[0]
  lb_target_group_arn    = aws_lb_target_group.frontend_https.arn
}

resource "aws_autoscaling_attachment" "frontend_keycloak_acm" {
  for_each               = module.eks.eks_managed_node_groups
  autoscaling_group_name = each.value.node_group_autoscaling_group_names[0]
  lb_target_group_arn    = aws_lb_target_group.frontend_keycloak_acm.arn
}

# NOTE: The EKS cluster control-plane log group (/aws/eks/<name>/cluster) is
# managed by module.eks (create_cloudwatch_log_group = true above).
# The orphaned log group is cleaned automatically by scripts/aws-pre-apply.sh,
# which is called by make tf-apply-aws before every apply.

# ── LAMBDA FORWARDER SUBSCRIPTION ────────────────────────────────────────────
# Uncomment after deploying the Datadog Lambda Forwarder CloudFormation stack.
# Docs: https://docs.datadoghq.com/logs/guide/forwarder/
#
# Replace the ARN below with your deployed forwarder Lambda function ARN.
# The forwarder is deployed per-region from:
# https://github.com/DataDog/datadog-serverless-functions/releases
#
# variable "datadog_forwarder_lambda_arn" {
#   description = "ARN of the deployed Datadog Lambda Forwarder"
#   type        = string
#   default     = "" # e.g. arn:aws:lambda:eu-west-1:123456789:function:datadog-log-forwarder
# }
#
# resource "aws_cloudwatch_log_subscription_filter" "finance_app_to_datadog" {
#   name            = "finance-app-to-datadog"
#   log_group_name  = aws_cloudwatch_log_group.finance_app.name
#   filter_pattern  = ""   # empty = forward all logs; adjust for cost control
#   destination_arn = var.datadog_forwarder_lambda_arn
#
#   depends_on = [aws_lambda_permission.allow_cloudwatch]
# }
#
# resource "aws_lambda_permission" "allow_cloudwatch" {
#   statement_id  = "AllowExecutionFromCloudWatch"
#   action        = "lambda:InvokeFunction"
#   function_name = var.datadog_forwarder_lambda_arn
#   principal     = "logs.amazonaws.com"
#   source_arn    = "${aws_cloudwatch_log_group.finance_app.arn}:*"
# }
# ─────────────────────────────────────────────────────────────────────────────

# =============================================================================
# ── DATADOG INTEGRATION ──
# =============================================================================
# All resources in this section require the Datadog Terraform provider and a
# valid DD_API_KEY. Uncomment only after:
#   1. The Datadog provider block above is uncommented and configured
#   2. TF_VAR_datadog_api_key is set in your shell (never in terraform.tfvars)
#   3. The IAM role above is created (first apply without this section)
#
# Docs: https://registry.terraform.io/providers/DataDog/datadog/latest/docs
# AWS integration guide: https://docs.datadoghq.com/integrations/amazon_web_services/

# resource "datadog_integration_aws" "main" {
#   account_id = data.aws_caller_identity.current.account_id
#   role_name  = aws_iam_role.datadog_integration.name
#
#   # Filter which EC2/EKS resources to monitor by tag
#   # Docs: https://docs.datadoghq.com/integrations/amazon_web_services/#resource-collection
#   filter_tags = [
#     "env:${var.environment}",
#     "Project:finance-sample-app",
#   ]
#
#   # Collect host-level tags from EC2 instance metadata
#   host_tags = [
#     "env:${var.environment}",
#     "cluster:${var.cluster_name}",
#   ]
#
#   # Enable specific AWS service integrations
#   account_specific_namespace_rules = {
#     api_gateway             = true
#     auto_scaling            = true
#     aws_eks                 = true
#     elastic_load_balancing  = true
#     lambda                  = true
#     rds                     = true   # set to true if using RDS instead of containerised Postgres
#     s3                      = false  # disable if not in use — reduces metric volume
#   }
# }

# ── DATADOG MONITOR: High payment error rate ──────────────────────────────────
# Uncomment to create an alert that fires when payment errors exceed 5% over 5 min.
# Adjust thresholds per your SLA requirements.
#
# resource "datadog_monitor" "payment_error_rate" {
#   name    = "[${var.environment}] Finance — High payment error rate"
#   type    = "query alert"
#   message = <<-EOT
#     Payment error rate exceeded 5% over the last 5 minutes.
#     Runbook: https://wiki.example.com/runbooks/payment-errors
#     @pagerduty-finance-oncall
#   EOT
#
#   query = "sum(last_5m):sum:finance.payment.initiated{env:${var.environment},status:error}.as_rate() / sum:finance.payment.initiated{env:${var.environment}}.as_rate() * 100 > 5"
#
#   monitor_thresholds {
#     critical          = 5
#     critical_recovery = 2
#     warning           = 3
#     warning_recovery  = 1
#   }
#
#   tags = [
#     "env:${var.environment}",
#     "service:gateway-api",
#     "team:finance-platform",
#   ]
#
#   notify_no_data    = false
#   renotify_interval = 60
# }

# ── DATADOG DASHBOARD: Finance overview ───────────────────────────────────────
# Uncomment to provision a starter Finance observability dashboard via Terraform.
# Extend the widget list with your key metrics and SLIs.
#
# resource "datadog_dashboard" "finance_overview" {
#   title        = "Finance App — Service Overview (${var.environment})"
#   description  = "Key metrics for the Finance sample app: payments, fraud, ledger, batch jobs"
#   layout_type  = "ordered"
#   is_read_only = false
#
#   widget {
#     timeseries_definition {
#       title = "Payment Initiation Rate"
#       request {
#         q            = "sum:finance.payment.initiated{env:${var.environment}}.as_rate()"
#         display_type = "line"
#       }
#     }
#   }
#
#   widget {
#     timeseries_definition {
#       title = "Fraud Score Distribution"
#       request {
#         q            = "avg:finance.fraud.score{env:${var.environment}} by {fraud_score_bucket}"
#         display_type = "bars"
#       }
#     }
#   }
#
#   widget {
#     check_status_definition {
#       title     = "Batch Processor — Last Run Status"
#       check     = "datadog.agent.up"
#       grouping  = "cluster"
#       tags      = ["service:batch-processor", "env:${var.environment}"]
#     }
#   }
# }

# ── DATADOG SLO: Payment API availability ─────────────────────────────────────
# Uncomment to define an SLO for the Payment API targeting 99.9% availability.
# Docs: https://docs.datadoghq.com/monitors/service_level_objectives/
#
# resource "datadog_service_level_objective" "payment_availability" {
#   name        = "Payment API Availability (${var.environment})"
#   type        = "metric"
#   description = "99.9% of payment requests succeed over a 30-day rolling window"
#
#   query {
#     numerator   = "sum:finance.payment.initiated{env:${var.environment},status:success}.as_count()"
#     denominator = "sum:finance.payment.initiated{env:${var.environment}}.as_count()"
#   }
#
#   thresholds {
#     timeframe       = "30d"
#     target          = 99.9
#     warning         = 99.95
#   }
#
#   tags = [
#     "env:${var.environment}",
#     "service:gateway-api",
#   ]
# }

# =============================================================================
# END DATADOG INTEGRATION
# =============================================================================
