# =============================================================================
# Finance Sample App — Datadog Observability Configuration
# =============================================================================
# Provisions all Datadog resources for the Finance sample app:
#   - Log index with correct filter and retention
#   - Log index ordering (finance index before main)
#   - Log processing pipeline (structured JSON parsing)
#   - Monitors (pod restarts, error rate, log volume)
#   - Dashboard (Finance app overview)
#
# Prerequisites:
#   1. make tf-apply-aws        — EKS cluster and Datadog Agent deployed
#   2. make deploy-k8s-eks      — Finance app running on EKS
#   3. make deploy-k8s-dd       — Datadog Agent running, sending data
#   4. Set secrets in AWS Secrets Manager:
#        aws secretsmanager put-secret-value --secret-id finance-app/staging/dd-api-key --secret-string <key>
#        aws secretsmanager put-secret-value --secret-id finance-app/staging/dd-app-key --secret-string <key>
#   5. Export keys as env vars (never put in tfvars):
#        export TF_VAR_datadog_api_key="$(aws secretsmanager get-secret-value \
#          --secret-id finance-app/staging/dd-api-key --query SecretString --output text)"
#        export TF_VAR_datadog_app_key="$(aws secretsmanager get-secret-value \
#          --secret-id finance-app/staging/dd-app-key --query SecretString --output text)"
#
# Docs: https://registry.terraform.io/providers/DataDog/datadog/latest/docs
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    datadog = {
      source  = "DataDog/datadog"
      version = "~> 3.0"
    }
    # Used only to generate a random suffix for the log index name (see
    # random_id.log_index_suffix below) so destroy/recreate cycles never hit
    # Datadog's permanent index-name reservation.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "datadog" {
  api_key = var.datadog_api_key
  app_key = var.datadog_app_key
  api_url = "https://api.${var.datadog_site}/"
}

# =============================================================================
# LOCALS
# =============================================================================

locals {
  # Tag filter used consistently across index, pipeline, monitors, dashboard
  cluster_filter   = "kube_cluster_name:${var.cluster_name}"
  env_filter       = "env:${var.environment}"
  namespace_filter = "kube_namespace:finance"

  # Combined filter for all finance app logs.
  # Uses kube_namespace:finance only so the index captures logs from both
  # local k3s (no kube_cluster_name tag) and EKS (kube_cluster_name:finance-app).
  finance_log_filter = local.namespace_filter

  common_tags = [
    "env:${var.environment}",
    "cluster:${var.cluster_name}",
    "managed-by:terraform",
    "app:finance-sample-app",
  ]

  # ── Synthetic test target URLs ────────────────────────────────────────
  # Datadog's public testing locations (e.g. aws:eu-west-1) cannot resolve
  # in-cluster Kubernetes DNS. When synthetic_target_base_url is set (to the
  # frontend nginx LoadBalancer hostname), tests go through nginx's public
  # reverse proxy instead of internal *.svc.cluster.local addresses — see
  # deploy/kubernetes/base/services/frontend.yaml for the routing table.
  # When unset, tests fall back to internal DNS, which only works if you
  # additionally deploy a Datadog Synthetics Private Location in-cluster.
  synthetic_use_public_proxy = var.synthetic_target_base_url != ""

  synthetic_gateway_base = local.synthetic_use_public_proxy ? var.synthetic_target_base_url : "http://gateway-api.finance.svc.cluster.local:8080"

  synthetic_account_base = local.synthetic_use_public_proxy ? "${var.synthetic_target_base_url}/internal/accounts" : "http://account-service.finance.svc.cluster.local:8081/v1/accounts"

  synthetic_account_health_url = local.synthetic_use_public_proxy ? "${var.synthetic_target_base_url}/internal/account-service/health" : "http://account-service.finance.svc.cluster.local:8081/health"

  synthetic_transaction_health_url = local.synthetic_use_public_proxy ? "${var.synthetic_target_base_url}/internal/transaction-service/health" : "http://transaction-service.finance.svc.cluster.local:8082/health"

  synthetic_transactions_base = local.synthetic_use_public_proxy ? "${var.synthetic_target_base_url}/internal/transactions" : "http://transaction-service.finance.svc.cluster.local:8082/v1/payments"

  # Keycloak's token endpoint is exposed on the SAME frontend nginx
  # LoadBalancer over plain HTTP at /auth/ (see
  # deploy/kubernetes/base/services/frontend.yaml). There is also a :8443
  # HTTPS route to Keycloak, but it uses a self-signed cert, and Datadog's
  # multistep API tests do not reliably honour accept_self_signed/
  # allow_insecure for individual steps — verified empirically (the step
  # failed with "SSL: Self-signed certificate" even with
  # accept_self_signed = true set). The plain-HTTP /auth/ route sidesteps
  # that entirely. Auth-dependent synthetic tests log in here as their
  # first step to get a fresh, short-lived JWT (Keycloak's default access
  # token lifetime is 5 minutes) rather than relying on a static bearer
  # token that goes stale.
  synthetic_keycloak_token_url = "${local.synthetic_gateway_base}/auth/realms/finance/protocol/openid-connect/token"
}

# =============================================================================
# LOG INDEX
# =============================================================================
# A dedicated index for finance app logs gives:
#   - Separate retention policy from the default 'main' index
#   - Faster queries (smaller index, focused filter)
#   - Independent daily quota management
#
# Docs: https://docs.datadoghq.com/logs/log_configuration/indexes/

# Datadog never truly deletes a log index name once used — it just becomes
# permanently reserved (a 409 Conflict on any future attempt to reuse it).
# Appending a random suffix means `terraform destroy` + `terraform apply`
# (or a full teardown/rebuild cycle) can never collide with a previously
# used name. The random value lives only in Terraform state: destroying the
# index resource removes it from state too, so the next apply generates a
# brand-new suffix automatically — no manual version-bumping (v2, v3, v4...)
# ever needed again.
resource "random_id" "log_index_suffix" {
  byte_length = 3
}

resource "datadog_logs_index" "finance_app" {
  name           = "finance-logs-${random_id.log_index_suffix.hex}"
  retention_days = var.log_retention_days

  # Only index logs from the finance namespace on the finance-app cluster.
  # Logs not matching this filter fall through to the next index (main).
  filter {
    query = local.finance_log_filter
  }

  # Best practice: don't pay to index verbose DEBUG-level noise. The status
  # remapper processor below (in datadog_logs_custom_pipeline.finance_app)
  # maps each service's level/severity field to Datadog's standard 'status'
  # facet, so this can filter on status:debug directly. sample_rate = 1
  # means 100% of matching logs are excluded (dropped before indexing/
  # billing) — set it lower (e.g. 0.1) instead of 1 if you want to keep a
  # small sample of DEBUG logs for troubleshooting rather than none at all.
  # Docs: https://docs.datadoghq.com/logs/log_configuration/indexes/#exclusion-filters
  exclusion_filter {
    name       = "Drop DEBUG-level logs"
    is_enabled = true
    filter {
      query       = "status:debug"
      sample_rate = 1
    }
  }

  # Daily quota — prevent runaway log ingestion from crashing the budget.
  # NOTE: the Datadog API's daily_limit is denominated in BYTES, not MB.
  # 500 MB/day for staging == 500,000,000 bytes. A previous value of
  # literal `500` (500 bytes — about one log line) silently exhausted the
  # quota within seconds of pod startup, making every subsequent finance
  # namespace log invisible in Log Explorer even though the Agent reported
  # successful HTTP delivery (the index enforces the quota after intake).
  daily_limit                              = 500000000
  daily_limit_warning_threshold_percentage = 80

  # Note: flex_retention_days requires Flex Logs to be enabled on the org.
  # Remove the comment below and set to enable if your org supports it:
  # flex_retention_days = 90
}

# =============================================================================
# LOG INDEX ORDER — intentionally NOT managed by Terraform
# =============================================================================
# datadog_logs_index_order requires listing ALL indexes in the org, including
# any personal or pre-existing ones. Managing it here would silently overwrite
# the org's full index order every time tf-apply-dd runs, potentially breaking
# other indexes that have nothing to do with this project.
#
# Instead, set the index order manually once in the Datadog UI:
#   Logs > Configuration > Indexes > drag finance-app to the top
#
# This ensures finance logs are routed to the finance-app index first.
# Docs: https://docs.datadoghq.com/logs/log_configuration/indexes/#indexes-filters

# =============================================================================
# LOG PROCESSING PIPELINE
# =============================================================================
# Parses structured JSON logs emitted by all finance services and enriches
# them with finance-domain attributes for fast filtering and dashboarding.
#
# Docs: https://docs.datadoghq.com/logs/log_configuration/pipelines/

resource "datadog_logs_custom_pipeline" "finance_app" {
  name       = "Finance App — ${var.cluster_name}"
  is_enabled = true

  # Scope to finance logs only
  filter {
    query = local.finance_log_filter
  }

  # ── Processor 1: JSON parser ──────────────────────────────────────────────
  # All finance services emit structured JSON. Use a grok parser to extract
  # the JSON body into attributes (json_parser was removed in provider v3;
  # grok %{data::json} is the equivalent).
  processor {
    grok_parser {
      name       = "Parse JSON log body"
      is_enabled = true
      source     = "message"
      grok {
        support_rules = ""
        match_rules   = "json_rule %%{data::json}"
      }
    }
  }

  # ── Processor 1b: PostgreSQL native log level category ────────────
  # BUG FIX: postgres emits plain-text logs (e.g.
  # "2026-07-02 14:17:25 UTC [26] LOG:  checkpoint complete: ...") rather
  # than the JSON our other services emit. The JSON parser above doesn't
  # match these lines, so no 'level' attribute is ever extracted, and
  # Datadog's fallback automatic status detection flags them as
  # status:error — routine checkpoint/autovacuum LOG lines were showing up
  # as errors, polluting error-rate dashboards and monitors, and even a
  # real "FATAL" auth error was indistinguishable from routine "LOG" noise
  # once both were mis-bucketed the same way. Categorise by the actual
  # PostgreSQL severity keyword so the status remapper below has something
  # correct to source from.
  processor {
    category_processor {
      name       = "Map PostgreSQL native severity to a status category"
      is_enabled = true
      target     = "pg_status"
      category {
        name = "info"
        filter {
          query = "service:postgres (\"LOG:\" OR \"NOTICE:\" OR \"INFO:\" OR \"STATEMENT:\" OR \"DEBUG:\")"
        }
      }
      category {
        name = "warning"
        filter {
          query = "service:postgres \"WARNING:\""
        }
      }
      category {
        name = "error"
        filter {
          query = "service:postgres (\"ERROR:\" OR \"FATAL:\" OR \"PANIC:\")"
        }
      }
    }
  }

  # ── Processor 1c: dd-java-agent startup banner status category ────
  # BUG FIX: account-service and batch-processor's dd-java-agent prints its
  # own startup diagnostics straight to stderr as plain text (e.g.
  # "[dd.trace 2026-07-03 08:23:18:379 +0000] [dd-task-scheduler] INFO
  # datadog.trace.agent.core.StatusLogger - DATADOG TRACER CONFIGURATION
  # ..."), plus a couple of bare JVM lines ("Picked up JAVA_TOOL_OPTIONS: ...",
  # "OpenJDK 64-Bit Server VM warning: ..."). None of these are JSON, so (same
  # root cause as Processor 1b above) they carry no 'level' attribute and
  # Datadog's automatic status detection defaulted every single one of them to
  # status:error -- meaning both Java services logged a burst of ~8 fake
  # errors on every single pod start/restart, which is indistinguishable from
  # a real problem in the error-rate monitor and dashboards.
  processor {
    category_processor {
      name       = "Map dd-java-agent startup banner to a status category"
      is_enabled = true
      target     = "jvm_status"
      category {
        name = "info"
        filter {
          query = "service:(account-service OR batch-processor) ((\"[dd.trace\" AND \"INFO\") OR \"Picked up JAVA_TOOL_OPTIONS\")"
        }
      }
      category {
        name = "warning"
        filter {
          query = "service:(account-service OR batch-processor) ((\"[dd.trace\" AND \"WARN\") OR \"VM warning\")"
        }
      }
      category {
        name = "error"
        filter {
          query = "service:(account-service OR batch-processor) \"[dd.trace\" AND \"ERROR\""
        }
      }
    }
  }

  # ── Processor 2: Status remapper ─────────────────────────────────
  # Map the application-level 'level' / 'severity' field (for JSON-emitting
  # services), 'pg_status' (for postgres's plain-text logs, see Processor 1b),
  # or 'jvm_status' (for the dd-java-agent startup banner, see Processor 1c)
  # to the Datadog official log status so logs appear with the right colour
  # in Log Explorer.
  processor {
    status_remapper {
      name       = "Map log level to Datadog status"
      is_enabled = true
      sources    = ["level", "severity", "msg.level", "msg.severity", "pg_status", "jvm_status"]
    }
  }

  # ── Processor 3: Service remapper ────────────────────────────────────────
  # Use the Kubernetes deployment name as the Datadog service tag so traces,
  # logs, and metrics are correlated under the same service in APM.
  processor {
    service_remapper {
      name       = "Map kube_deployment to service"
      is_enabled = true
      sources    = ["kube_deployment", "service", "msg.service"]
    }
  }

  # ── Processor 4: Trace ID remapper ───────────────────────────────────────
  # When APM is enabled (Learning Progression Step 3), dd.trace_id is injected
  # into every log line. This processor links logs to their parent trace.
  # Docs: https://docs.datadoghq.com/tracing/other_telemetry/connect_logs_and_traces/
  processor {
    trace_id_remapper {
      name       = "Link logs to APM traces via trace_id"
      is_enabled = true
      sources    = ["dd.trace_id", "msg.dd.trace_id"]
    }
  }

  # ── Processor 5: Finance domain attribute remapper ───────────────────────
  # Promote finance-specific fields to top-level attributes so they appear
  # as facets in Log Explorer without manual parsing.
  processor {
    attribute_remapper {
      name                 = "Promote transaction.type to facet"
      is_enabled           = true
      sources              = ["msg.transaction.type"]
      source_type          = "attribute"
      target               = "transaction.type"
      target_type          = "attribute"
      preserve_source      = true
      override_on_conflict = false
    }
  }

  processor {
    attribute_remapper {
      name                 = "Promote fraud.score_bucket to facet"
      is_enabled           = true
      sources              = ["msg.fraud.score_bucket"]
      source_type          = "attribute"
      target               = "fraud.score_bucket"
      target_type          = "attribute"
      preserve_source      = true
      override_on_conflict = false
    }
  }

  processor {
    attribute_remapper {
      name                 = "Promote account.tier to facet"
      is_enabled           = true
      sources              = ["msg.account.tier"]
      source_type          = "attribute"
      target               = "account.tier"
      target_type          = "attribute"
      preserve_source      = true
      override_on_conflict = false
    }
  }
}

# =============================================================================
# METRICS FROM SPANS
# =============================================================================
# Generates custom metrics directly from indexed APM spans — no DogStatsD code
# required. Metrics become available in the Metrics Explorer and dashboards as
# soon as APM instrumentation is active (Learning Progression Step 3).
#
# Resource: datadog_spans_metric
# Docs: https://docs.datadoghq.com/tracing/trace_pipeline/generate_metrics/
# Terraform: https://registry.terraform.io/providers/DataDog/datadog/latest/docs/resources/spans_metric

# finance.payment.hits — count of payment spans, grouped by transaction type and currency
# Filters on the payment.authorize span (not the gateway-api entry span) because
# the payment.currency/transaction.type business tags are only set on that nested
# span — confirmed live: filtering on the FastAPI entry span returns "N/A" for
# both group_by dimensions.
resource "datadog_spans_metric" "payment_hits" {
  name = "finance.payment.hits"

  compute {
    aggregation_type = "count"
  }

  filter {
    query = "operation_name:payment.authorize"
  }

  group_by {
    path     = "@transaction.type"
    tag_name = "transaction_type"
  }

  group_by {
    path     = "@payment.currency"
    tag_name = "currency"
  }

  group_by {
    path     = "env"
    tag_name = "env"
  }
}

# finance.payment.duration — distribution of payment span latency (nanoseconds)
# Percentiles (p50/p75/p90/p95/p99) are automatically generated by Datadog.
# Filters on the payment.authorize span for the same reason as payment_hits above.
resource "datadog_spans_metric" "payment_duration" {
  name = "finance.payment.duration"

  compute {
    aggregation_type    = "distribution"
    include_percentiles = true
    path                = "@duration"
  }

  filter {
    query = "operation_name:payment.authorize"
  }

  group_by {
    path     = "@transaction.type"
    tag_name = "transaction_type"
  }

  group_by {
    path     = "@payment.currency"
    tag_name = "currency"
  }

  group_by {
    path     = "env"
    tag_name = "env"
  }
}

# finance.fraud.hits — count of fraud-scoring spans, grouped by risk bucket
# Use @fraud.score_bucket (low/medium/high) rather than the raw float to avoid
# high-cardinality tag values.
resource "datadog_spans_metric" "fraud_hits" {
  name = "finance.fraud.hits"

  compute {
    aggregation_type = "count"
  }

  filter {
    query = "service:fraud-detection"
  }

  group_by {
    path     = "@fraud.score_bucket"
    tag_name = "score_bucket"
  }

  group_by {
    path     = "env"
    tag_name = "env"
  }
}

# finance.fraud.score — distribution of the raw fraud score, computed from the
# numeric @fraud.score span tag (percentiles auto-generated). This replaces the
# old DogStatsD gauge; the raw float is safe here because it's aggregated into a
# distribution, not used as a grouping tag value. Grouped by the bounded bucket.
resource "datadog_spans_metric" "fraud_score" {
  name = "finance.fraud.score"

  compute {
    aggregation_type    = "distribution"
    include_percentiles = true
    path                = "@fraud.score"
  }

  filter {
    query = "service:fraud-detection"
  }

  group_by {
    path     = "@fraud.score_bucket"
    tag_name = "score_bucket"
  }

  group_by {
    path     = "env"
    tag_name = "env"
  }
}

# finance.batch.records_processed — distribution of records written per batch step
# Surfaces in dashboards as sum/p95. Tagged by job name and terminal status so
# you can alert on partial runs (e.g. job_status:partial or job_status:failed).
resource "datadog_spans_metric" "batch_records" {
  name = "finance.batch.records_processed"

  compute {
    aggregation_type    = "distribution"
    include_percentiles = false
    path                = "@job.records_processed"
  }

  filter {
    query = "service:batch-processor"
  }

  group_by {
    path     = "@job.name"
    tag_name = "job_name"
  }

  group_by {
    path     = "@job.status"
    tag_name = "job_status"
  }

  group_by {
    path     = "env"
    tag_name = "env"
  }
}

# finance.notification.sent — count of alert.send spans (replaces the old
# DogStatsD counter in notification-service), grouped by channel + event type.
resource "datadog_spans_metric" "notification_sent" {
  name = "finance.notification.sent"

  compute {
    aggregation_type = "count"
  }

  filter {
    query = "service:notification-service operation_name:alert.send"
  }

  group_by {
    path     = "@notification.channel"
    tag_name = "channel"
  }

  group_by {
    path     = "@notification.event_type"
    tag_name = "event_type"
  }

  group_by {
    path     = "env"
    tag_name = "env"
  }
}

# finance.notification.dispatch_time — distribution of alert.send span latency
# (replaces the old DogStatsD histogram). Percentiles auto-generated.
resource "datadog_spans_metric" "notification_dispatch_time" {
  name = "finance.notification.dispatch_time"

  compute {
    aggregation_type    = "distribution"
    include_percentiles = true
    path                = "@duration"
  }

  filter {
    query = "service:notification-service operation_name:alert.send"
  }

  group_by {
    path     = "@notification.channel"
    tag_name = "channel"
  }

  group_by {
    path     = "env"
    tag_name = "env"
  }
}

# finance.payment.success — count of successful payment.authorize spans (status:ok).
# Powers the Business/Analyst/Admin dashboards' payment success-rate widgets.
resource "datadog_spans_metric" "finance_payment_success" {
  name = "finance.payment.success"

  compute {
    aggregation_type = "count"
  }

  filter {
    query = "operation_name:payment.authorize status:ok"
  }

  group_by {
    path     = "env"
    tag_name = "env"
  }
}

# finance.payment.failed — count of failed payment.authorize spans (status:error).
# No high-cardinality tags (e.g. transaction IDs) are added as group_by dimensions.
resource "datadog_spans_metric" "finance_payment_failed" {
  name = "finance.payment.failed"

  compute {
    aggregation_type = "count"
  }

  filter {
    query = "operation_name:payment.authorize status:error"
  }

  group_by {
    path     = "env"
    tag_name = "env"
  }
}

# finance.ledger.commit.errors — count of failed ledger.commit spans.
# Feeds the Analyst dashboard's Settlement & Reconciliation group.
resource "datadog_spans_metric" "finance_ledger_commit_errors" {
  name = "finance.ledger.commit.errors"

  compute {
    aggregation_type = "count"
  }

  filter {
    query = "operation_name:ledger.commit status:error"
  }

  group_by {
    path     = "env"
    tag_name = "env"
  }
}

# =============================================================================
# METRICS FROM LOGS
# =============================================================================
# Generates custom metrics from indexed log events — counts log lines matching
# a query and makes the result available as a standard Datadog metric.
# Metrics are populated as long as logs flow into the finance-app index, even
# before APM is enabled.
#
# Resource: datadog_logs_metric
# Docs: https://docs.datadoghq.com/logs/log_configuration/logs_to_metrics/
# Terraform: https://registry.terraform.io/providers/DataDog/datadog/latest/docs/resources/logs_metric

# finance.logs.errors — count of error-level log lines, grouped by service
# Powers the Error Logs by Service timeseries widget in the dashboard and feeds
# the error_rate monitor below.
resource "datadog_logs_metric" "error_count" {
  name = "finance.logs.errors"

  compute {
    aggregation_type = "count"
  }

  filter {
    query = "${local.finance_log_filter} status:error"
  }

  group_by {
    path     = "service"
    tag_name = "service"
  }

  group_by {
    path     = "env"
    tag_name = "env"
  }
}

# finance.logs.payments_initiated — count of payment log events from gateway-api
# Useful as a cross-check against the span-based finance.payment.hits metric;
# a divergence between the two may indicate incomplete APM coverage.
resource "datadog_logs_metric" "payments_initiated" {
  name = "finance.logs.payments_initiated"

  compute {
    aggregation_type = "count"
  }

  filter {
    query = "${local.finance_log_filter} service:gateway-api @message:payment*"
  }

  group_by {
    path     = "env"
    tag_name = "env"
  }
}

# =============================================================================
# MONITORS
# =============================================================================
# Docs: https://docs.datadoghq.com/monitors/

# ── Monitor 1: Pod restart rate ──────────────────────────────────────────────
# Fires when any finance pod restarts more than 3 times in 15 minutes.
# Common causes: OOMKill, app crash, misconfigured secrets.

resource "datadog_monitor" "pod_restarts" {
  name    = "[Finance] Pod restart rate — ${var.cluster_name}"
  type    = "metric alert"
  message = <<-EOT
    ## Finance app pod restart spike

    Pod {{kube_deployment.name}} in namespace {{kube_namespace.name}} on cluster
    {{kube_cluster_name.name}} has restarted more than 3 times in 15 minutes.

    **Common causes:**
    - OOMKill: check memory limits in the Deployment spec
    - App crash: check pod logs in [Log Explorer](https://app.datadoghq.com/logs?query=${local.namespace_filter})
    - Bad secret/configmap: check for missing env vars at startup

    @pagerduty @slack-finance-alerts
  EOT

  query = "sum(last_15m):sum:kubernetes.containers.restarts{${local.namespace_filter}} by {kube_deployment}.as_count() > 3"

  monitor_thresholds {
    critical = 3
    warning  = 1
  }

  notify_no_data    = false
  renotify_interval = 60
  tags              = local.common_tags
}

# ── Monitor 2: Finance service error rate ────────────────────────────────────
# Fires when error-level logs exceed 20 per minute for a given service.
# Requires log collection to be active (Learning Progression Step 1).

resource "datadog_monitor" "error_rate" {
  name    = "[Finance] High error rate — ${var.cluster_name}"
  type    = "log alert"
  message = <<-EOT
    ## High error rate detected in Finance app

    Service {{service.name}} is producing more than 20 error logs per minute
    in cluster {{kube_cluster_name.name}}.

    [View logs](https://app.datadoghq.com/logs?query=${local.finance_log_filter} status:error)

    @slack-finance-alerts
  EOT

  # Use index "*" (all indexes) so the monitor validates before the finance-app
  # index exists. Logs are already scoped by the filter query itself.
  query = "logs(\"${local.finance_log_filter} status:error\").index(\"*\").rollup(\"count\").last(\"5m\") > 20"

  monitor_thresholds {
    critical = 20
    warning  = 10
  }

  notify_no_data    = false
  renotify_interval = 30
  tags              = local.common_tags

  depends_on = [datadog_logs_index.finance_app]
}

# ── Monitor 3: Pods not running ───────────────────────────────────────────────
# Fires when fewer than the expected number of pods are running in the finance namespace.

resource "datadog_monitor" "pods_not_running" {
  name    = "[Finance] Pods not running — ${var.cluster_name}"
  type    = "metric alert"
  message = <<-EOT
    ## Finance app pods not running

    The number of running pods in kube_namespace:finance on ${var.cluster_name}
    has dropped below the expected minimum.

    Check pod status:
      kubectl get pods -n finance

    @slack-finance-alerts
  EOT

  query = "min(last_5m):sum:kubernetes.pods.running{${local.namespace_filter}} < 8"

  monitor_thresholds {
    critical = 8
    warning  = 10
  }

  notify_no_data    = true
  no_data_timeframe = 10
  renotify_interval = 30
  tags              = local.common_tags
}

# =============================================================================
# DASHBOARD
# =============================================================================
# Finance app overview dashboard.
# Docs: https://docs.datadoghq.com/dashboards/

resource "datadog_dashboard" "finance_overview" {
  title       = "Finance App — ${var.cluster_name} Overview"
  description = "Infrastructure and application health for the Finance sample app on EKS cluster ${var.cluster_name}. Managed by Terraform — deploy/terraform/datadog/."
  layout_type = "ordered"
  # tags are restricted in this org to team: and ai: only
  # tags = local.common_tags

  # ── Row 1: Pod health ──────────────────────────────────────────────────────
  widget {
    group_definition {
      title            = "Pod Health"
      layout_type      = "ordered"
      background_color = "blue"

      widget {
        query_value_definition {
          title       = "Running Pods"
          title_size  = "16"
          title_align = "left"
          autoscale   = true
          precision   = 0

          request {
            q          = "sum:kubernetes.pods.running{${local.namespace_filter}}"
            aggregator = "last"
          }
        }
      }

      widget {
        query_value_definition {
          title       = "Pod Restarts (15m)"
          title_size  = "16"
          title_align = "left"
          autoscale   = true
          precision   = 0

          request {
            q          = "sum:kubernetes.containers.restarts{${local.namespace_filter}}.as_count()"
            aggregator = "sum"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Pod Restarts by Deployment"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:kubernetes.containers.restarts{${local.namespace_filter}} by {kube_deployment}.as_count()"
            display_type = "bars"
          }
        }
      }
    }
  }

  # ── Row 2: CPU & Memory ────────────────────────────────────────────────────
  widget {
    group_definition {
      title            = "CPU & Memory"
      layout_type      = "ordered"
      background_color = "green"

      widget {
        timeseries_definition {
          title       = "CPU Usage by Deployment"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "avg:kubernetes.cpu.usage.total{${local.namespace_filter}} by {kube_deployment}"
            display_type = "line"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Memory Usage by Deployment"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "avg:kubernetes.memory.usage{${local.namespace_filter}} by {kube_deployment}"
            display_type = "line"
          }
        }
      }
    }
  }

  # ── Row 3: Logs ────────────────────────────────────────────────────────────
  widget {
    group_definition {
      title            = "Log Volume"
      layout_type      = "ordered"
      background_color = "yellow"

      widget {
        timeseries_definition {
          title       = "Log Volume by Service"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            log_query {
              index        = datadog_logs_index.finance_app.name
              search_query = local.finance_log_filter
              compute_query {
                aggregation = "count"
              }
              group_by {
                facet = "service"
                limit = 10
                sort_query {
                  aggregation = "count"
                  order       = "desc"
                }
              }
            }
            display_type = "bars"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Error Logs by Service"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            log_query {
              index        = datadog_logs_index.finance_app.name
              search_query = "${local.finance_log_filter} status:error"
              compute_query {
                aggregation = "count"
              }
              group_by {
                facet = "service"
                limit = 10
                sort_query {
                  aggregation = "count"
                  order       = "desc"
                }
              }
            }
            display_type = "bars"
          }
        }
      }
    }
  }

  # ── Row 4: APM Service Health ────────────────────────────────────────────
  widget {
    group_definition {
      title            = "APM Service Health"
      layout_type      = "ordered"
      background_color = "vivid_blue"

      widget {
        timeseries_definition {
          title       = "Request Rate by Service"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:trace.fastapi.request.hits{${local.env_filter}} by {service}.as_rate()"
            display_type = "line"
          }

          request {
            q            = "sum:trace.servlet.request.hits{${local.env_filter}} by {service}.as_rate()"
            display_type = "line"
          }

          request {
            q            = "sum:trace.express.request.hits{${local.env_filter}} by {service}.as_rate()"
            display_type = "line"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Error Rate by Service"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:trace.fastapi.request.errors{${local.env_filter}} by {service}.as_rate()"
            display_type = "bars"
          }

          request {
            q            = "sum:trace.servlet.request.errors{${local.env_filter}} by {service}.as_rate()"
            display_type = "bars"
          }

          request {
            q            = "sum:trace.express.request.errors{${local.env_filter}} by {service}.as_rate()"
            display_type = "bars"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "p95 Latency by Service (ms)"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "p95:trace.fastapi.request{${local.env_filter}} by {service}"
            display_type = "line"
          }

          request {
            q            = "p95:trace.servlet.request{${local.env_filter}} by {service}"
            display_type = "line"
          }

          request {
            q            = "p95:trace.express.request{${local.env_filter}} by {service}"
            display_type = "line"
          }
        }
      }
    }
  }

  # ── Row 5: DogStatsD Custom Metrics ───────────────────────────────────────
  widget {
    group_definition {
      title            = "Finance Custom Metrics (span-based)"
      layout_type      = "ordered"
      background_color = "orange"

      widget {
        query_value_definition {
          title       = "Payments Initiated (1h)"
          title_size  = "16"
          title_align = "left"
          autoscale   = true
          precision   = 0

          request {
            q          = "sum:finance.payment.hits{${local.env_filter}}.as_count()"
            aggregator = "sum"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Payment Initiated Rate by Currency"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:finance.payment.hits{${local.env_filter}} by {currency}.as_rate()"
            display_type = "bars"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Payment Duration p95"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "p95:finance.payment.duration{${local.env_filter}}"
            display_type = "line"
          }
        }
      }
    }
  }

  # ── Row 6: Database Monitoring ────────────────────────────────────────────
  widget {
    group_definition {
      title            = "Database — PostgreSQL Ledger"
      layout_type      = "ordered"
      background_color = "gray"

      widget {
        timeseries_definition {
          title       = "DB Query Latency p95 (ms)"
          title_size  = "16"
          title_align = "left"
          show_legend = false

          request {
            q            = "p95:postgresql.query.duration{db:ledger,${local.env_filter}} * 1000"
            display_type = "line"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Active DB Connections"
          title_size  = "16"
          title_align = "left"
          show_legend = false

          request {
            q            = "avg:postgresql.connections{db:ledger,${local.env_filter}}"
            display_type = "line"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Stuck Pending Transactions"
          title_size  = "16"
          title_align = "left"
          show_legend = false

          request {
            q            = "max:finance.db.ledger.pending_count{${local.env_filter}}"
            display_type = "bars"
          }
        }
      }
    }
  }

  # ── Row 7: Messaging — ActiveMQ ───────────────────────────────────────────
  widget {
    group_definition {
      title            = "Messaging — ActiveMQ Artemis"
      layout_type      = "ordered"
      background_color = "vivid_orange"

      widget {
        timeseries_definition {
          title       = "Queue Depth by Queue"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "max:activemq.artemis.queue.message_count{${local.env_filter}} by {queue}"
            display_type = "line"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Consumer Count by Queue"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "min:activemq.artemis.queue.consumer_count{${local.env_filter}} by {queue}"
            display_type = "line"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Messages Added Rate"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:activemq.artemis.queue.messages_added{${local.env_filter}} by {queue}.as_rate()"
            display_type = "bars"
          }
        }
      }
    }
  }

  # ── Row 8: Finance Metrics from Spans & Logs ─────────────────────────────
  # These widgets use metrics generated by datadog_spans_metric and
  # datadog_logs_metric resources defined above. They are populated as soon as
  # APM instrumentation is active (Step 3) and logs are flowing (Step 1).
  widget {
    group_definition {
      title            = "Finance Metrics from Spans & Logs"
      layout_type      = "ordered"
      background_color = "purple"

      widget {
        timeseries_definition {
          title       = "Payment Requests (from spans)"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:finance.payment.hits{${local.env_filter}} by {transaction_type}"
            display_type = "bars"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Payment p95 Latency (from spans)"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "p95:finance.payment.duration{${local.env_filter}}"
            display_type = "line"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Fraud Score Distribution (from spans)"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:finance.fraud.hits{${local.env_filter}} by {score_bucket}"
            display_type = "bars"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Error Logs by Service (from logs metric)"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:finance.logs.errors{${local.env_filter}} by {service}"
            display_type = "bars"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Batch Records Processed (from spans)"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:finance.batch.records_processed{${local.env_filter}} by {job_name,job_status}"
            display_type = "bars"
          }
        }
      }
    }
  }
}

# =============================================================================
# ADDITIONAL MONITORS
# =============================================================================

# ── Monitor 4: Payment API high latency ──────────────────────────────────────────
# Fires when the p95 payment latency exceeds 2 s. Requires APM (Step 3).
resource "datadog_monitor" "payment_latency" {
  name    = "[Finance] Payment p95 latency high — ${var.cluster_name}"
  type    = "metric alert"
  message = <<-EOT
    ## Payment latency SLA breach

    p95 latency for POST /v1/payments on service gateway-api has exceeded
    the 2-second SLA threshold.

    - [APM Service page](https://app.datadoghq.com/apm/services/gateway-api)
    - [Trace Explorer](https://app.datadoghq.com/apm/traces?query=service:gateway-api%20@http.url_details.path:/v1/payments)

    @slack-finance-alerts
  EOT

  # p95 duration in nanoseconds from the finance.payment.duration spans metric
  query = "percentile(last_5m):p95:finance.payment.duration{${local.env_filter}} > 2000000000"

  monitor_thresholds {
    critical = 2000000000 # 2 s in nanoseconds
    warning  = 1000000000 # 1 s in nanoseconds
  }

  notify_no_data    = false
  renotify_interval = 30
  tags              = local.common_tags

  depends_on = [datadog_spans_metric.payment_duration]
}

# ── Monitor 5: Payment error rate ───────────────────────────────────────────
# Fires when more than 10% of payment spans are errors. Requires APM (Step 3).
resource "datadog_monitor" "payment_error_rate" {
  name    = "[Finance] Payment error rate — ${var.cluster_name}"
  type    = "metric alert"
  message = <<-EOT
    ## Payment error rate above threshold

    The error rate for POST /v1/payments has exceeded 10%.

    **Triage steps:**
    1. Check [APM Traces](https://app.datadoghq.com/apm/traces?query=service:gateway-api%20status:error) for error details
    2. Review [account-service logs](https://app.datadoghq.com/logs?query=service:account-service%20status:error)
    3. Check [PostgreSQL DBM](https://app.datadoghq.com/databases) for slow queries

    @slack-finance-alerts
  EOT

  # Count of error spans from gateway-api in a 5-minute window
  query = "sum(last_5m):sum:trace.fastapi.request.errors{${local.env_filter},service:gateway-api}.as_count() > 10"

  monitor_thresholds {
    critical = 10
    warning  = 5
  }

  notify_no_data    = false
  renotify_interval = 30
  tags              = local.common_tags
}

# ── Monitor 6: Fraud queue depth ───────────────────────────────────────────
# Fires when fraud.score.queue has >100 unprocessed messages, indicating
# fraud-detection is lagging. Requires ActiveMQ JMX check (Step 9).
resource "datadog_monitor" "fraud_queue_depth" {
  name    = "[Finance] Fraud score queue backlog — ${var.cluster_name}"
  type    = "metric alert"
  message = <<-EOT
    ## Fraud score queue backlog detected

    The fraud.score.queue has {{value}} unprocessed messages, which may delay
    payment confirmations and breach the SLA for real-time fraud detection.

    **Triage steps:**
    1. Check fraud-detection pod status: `kubectl get pods -n finance -l app=fraud-detection`
    2. Check consumer count: should be >= 1 for this queue
    3. Check [fraud-detection logs](https://app.datadoghq.com/logs?query=service:fraud-detection)

    @slack-finance-alerts
  EOT

  # NOTE: tag is "queue" (not "queue_name") with a leading underscore on the
  # value -- see the KNOWN QUIRK comment in
  # deploy/kubernetes/datadog/checks/activemq-check.yaml for why.
  query = "max(last_5m):max:activemq.artemis.queue.message_count{${local.env_filter},queue:_fraud.score.queue} > 100"

  monitor_thresholds {
    critical = 100
    warning  = 50
  }

  notify_no_data    = false
  renotify_interval = 30
  tags              = local.common_tags
}

# ── Monitor 6b: Fraud queue producer rate surge (Workshop Scenario 3) ──────
# fraud_queue_depth above only fires once fraud-detection falls BEHIND — at
# demo-scale traffic, the consumer trivially keeps up even at 3x the normal
# publish rate (Scenario 3's FRAUD_QUEUE_DUPLICATE_FACTOR), so depth never
# climbs above ~0 and that monitor never fires. This one instead watches the
# PRODUCER rate directly (messages_added), so it catches "someone tripled the
# publish rate" even when the consumer is fast enough to hide the symptom
# depth-wise — the actual point of Scenario 3 (it's a producer problem, not
# a consumer one). "change alert": % increase over the prior 10m window.
resource "datadog_monitor" "fraud_queue_producer_surge" {
  name    = "[Finance] Fraud score queue producer rate surge — ${var.cluster_name}"
  type    = "metric alert"
  message = <<-EOT
    ## Fraud score queue publish rate has surged

    fraud.score.queue's message production rate jumped {{value}}% versus the
    prior 10 minutes. Queue depth may look normal if fraud-detection is
    keeping up — that does NOT mean nothing is wrong. Check whether a
    producer (transaction-service, account-service) started publishing
    duplicates or retrying excessively before scaling the consumer.

    **Triage steps:**
    1. APM > Data Streams — check which producer's throughput moved
    2. APM > Deployment Tracking on transaction-service / account-service —
       correlate the jump with a recent rollout
    3. `kubectl logs -n finance deploy/transaction-service` for repeated
       publishes per payment

    @slack-finance-alerts
  EOT

  query = <<-EOT
    change(sum(last_10m),last_10m):sum:activemq.artemis.queue.messages_added{${local.env_filter},queue:_fraud.score.queue}.as_count() > 100
  EOT

  monitor_thresholds {
    critical = 100
    warning  = 50
  }

  notify_no_data    = false
  renotify_interval = 30
  tags              = local.common_tags
}

# ── Monitor 7: Stuck pending transactions (DBM custom query) ───────────────
# Uses the custom_query defined in the postgres Agent config.
# Fires when transactions are stuck in 'pending' for > 5 minutes.
resource "datadog_monitor" "stuck_pending_transactions" {
  name    = "[Finance] Stuck pending transactions — ${var.cluster_name}"
  type    = "metric alert"
  message = <<-EOT
    ## Stuck pending transactions detected

    {{value}} transactions have been in 'pending' status for more than 5 minutes.
    This may indicate a downstream service failure (fraud-detection, notification).

    **Triage steps:**
    1. Check [DBM Query Samples](https://app.datadoghq.com/databases/queries) for blocking queries
    2. Check fraud-detection queue depth (see fraud queue monitor)
    3. Review [transaction-service logs](https://app.datadoghq.com/logs?query=service:transaction-service)

    @slack-finance-alerts
  EOT

  query = "max(last_10m):max:finance.db.ledger.pending_count{${local.env_filter}} > 10"

  monitor_thresholds {
    critical = 10
    warning  = 5
  }

  notify_no_data    = false
  renotify_interval = 60
  tags              = local.common_tags
}

# ── Monitor 8: Ledger commit errors ─────────────────────────────────────────
# Fires when transaction-service fails to commit trades to the ledger.
# Wired to the finance.ledger.commit.errors span-based metric.
resource "datadog_monitor" "ledger_commit_errors" {
  name    = "[Finance] Ledger commit errors — ${var.cluster_name}"
  type    = "metric alert"
  message = <<-EOT
    ## Ledger commit failures detected

    {{value}} ledger commit errors in the last 5 minutes on transaction-service.
    A failed ledger commit means a trade was authorized but not durably recorded —
    this can lead to reconciliation discrepancies at end-of-day settlement.

    **Triage steps:**
    1. Check [transaction-service logs](https://app.datadoghq.com/logs?query=service:transaction-service%20status:error)
    2. Check [PostgreSQL DBM](https://app.datadoghq.com/databases) for connection/lock errors on the ledger table
    3. Review the affected traces: [APM Traces](https://app.datadoghq.com/apm/traces?query=operation_name:ledger.commit%20status:error)

    @slack-finance-alerts
  EOT

  query = "sum(last_5m):sum:finance.ledger.commit.errors{${local.env_filter}}.as_count() > 5"

  monitor_thresholds {
    critical = 5
    warning  = 2
  }

  notify_no_data    = false
  renotify_interval = 30
  tags              = local.common_tags
}

# ── Monitor 9: Reconciliation job low record count ──────────────────────────
# Fires when the end-of-day-reconciliation job completes successfully but
# processes far fewer records than expected — the monitor the workshop's
# Scenario 2 ("nightly reconciliation fails silently") discussion question
# asks facilitators to set up. Wired to the finance.batch.records_processed
# span-based metric (see the "Custom metrics" section above).
resource "datadog_monitor" "reconciliation_low_record_count" {
  name    = "[Finance] Reconciliation job processed unexpectedly few records — ${var.cluster_name}"
  type    = "metric alert"
  message = <<-EOT
    ## Reconciliation job record count anomaly

    The end-of-day-reconciliation job completed successfully but processed
    far fewer records than expected — this can mean a subset of accounts was
    silently excluded (e.g. a data integrity issue in the reader query), not
    that there was simply less activity to reconcile.

    **Triage steps:**
    1. Check [Data Jobs Monitoring](https://app.datadoghq.com/data-jobs) for the job's step-level record counts
    2. Check batch-processor logs for the run's records.read/records.written line
    3. Check DBM for the reconciliation query's actual row count vs. expected

    @slack-finance-alerts
  EOT

  query = "avg(last_1h):avg:finance.batch.records_processed{job_name:end-of-day-reconciliation,${local.env_filter}} < 5"

  monitor_thresholds {
    critical = 5
    warning  = 20
  }

  notify_no_data    = false
  renotify_interval = 60
  tags              = local.common_tags
}

# =============================================================================
# SERVICE LEVEL OBJECTIVES (SLOs)
# =============================================================================
# SLOs define and track service reliability targets.
# Docs: https://docs.datadoghq.com/monitors/service_level_objectives/

# ── SLO 1: Payment API availability (99.9%) ───────────────────────────────
# Tracks the ratio of successful payments to total payment requests.
# Uses span-based metrics for accuracy (counts actual APM spans).
resource "datadog_service_level_objective" "payment_availability" {
  name        = "[Finance] Payment API Availability — ${var.cluster_name}"
  type        = "metric"
  description = "99.9% of payment requests must succeed (non-5xx). Measured from APM spans on gateway-api POST /v1/payments."

  query {
    numerator   = "sum:trace.fastapi.request.hits{${local.env_filter},service:gateway-api,http.status_class:2xx}.as_count()"
    denominator = "sum:trace.fastapi.request.hits{${local.env_filter},service:gateway-api}.as_count()"
  }

  thresholds {
    timeframe = "7d"
    target    = 99.9
    warning   = 99.95
  }

  thresholds {
    timeframe = "30d"
    target    = 99.9
    warning   = 99.95
  }

  tags = local.common_tags
}

# ── SLO 2: Payment API latency (p95 < 1 s, 95% of the time) ───────────────
# Monitors that the p95 latency SLA is met over a 7-day rolling window.
resource "datadog_service_level_objective" "payment_latency" {
  name        = "[Finance] Payment API Latency SLO — ${var.cluster_name}"
  type        = "monitor"
  description = "p95 payment latency must stay below 2 s for 99% of any 7-day window."

  monitor_ids = [datadog_monitor.payment_latency.id]

  thresholds {
    timeframe = "7d"
    target    = 99
    warning   = 99.5
  }

  tags = local.common_tags
}

# ── SLO 3: Fraud queue consumer availability ─────────────────────────────
# Tracks that at least one consumer is active on fraud.score.queue.
# A consumer count of 0 means fraud-detection is down and payments stall.
resource "datadog_service_level_objective" "fraud_consumer_availability" {
  name        = "[Finance] Fraud Queue Consumer Availability — ${var.cluster_name}"
  type        = "monitor"
  description = "fraud.score.queue must have at least 1 active consumer 99.5% of the time."

  monitor_ids = [datadog_monitor.fraud_queue_depth.id]

  thresholds {
    timeframe = "7d"
    target    = 99.5
    warning   = 99.9
  }

  tags = local.common_tags
}

# =============================================================================
# PERSONA-BASED DASHBOARDS
# =============================================================================
# Four additional dashboards, each tailored to a specific audience, built from
# the same span-based and infrastructure metrics as the overview dashboard
# above. All widgets use local.env_filter / local.namespace_filter rather than
# hardcoded strings for portability across local k3s and EKS.
# Docs: https://docs.datadoghq.com/dashboards/
# =============================================================================

# ── Dashboard A: Technical ───────────────────────────────────────────────────
# Audience: SREs / on-call engineers. Infra health, APM, async processing,
# logs, and dependency (DB/messaging) status in one place.
resource "datadog_dashboard" "finance_technical" {
  title       = "Finance App — ${var.cluster_name} : Technical"
  description = "Technical/SRE view of the Finance sample app: infrastructure, APM, async processing, logs, and dependencies. Managed by Terraform — deploy/terraform/datadog/."
  layout_type = "ordered"
  # tags are restricted in this org to team: and ai: only

  # ── Row 1: Cluster & Pods ──────────────────────────────────────────────────
  widget {
    group_definition {
      title            = "Cluster & Pods"
      layout_type      = "ordered"
      background_color = "blue"

      widget {
        query_value_definition {
          title       = "Running Pods"
          title_size  = "16"
          title_align = "left"
          autoscale   = true
          precision   = 0

          request {
            q          = "sum:kubernetes.pods.running{${local.namespace_filter}}"
            aggregator = "last"
          }
        }
      }

      widget {
        query_value_definition {
          title       = "Pod Restarts (15m)"
          title_size  = "16"
          title_align = "left"
          autoscale   = true
          precision   = 0

          request {
            q          = "sum:kubernetes.containers.restarts{${local.namespace_filter}}.as_count()"
            aggregator = "sum"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Pod Restarts by Deployment"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:kubernetes.containers.restarts{${local.namespace_filter}} by {kube_deployment}.as_count()"
            display_type = "bars"
          }
        }
      }
    }
  }

  # ── Row 2: Resource Usage ──────────────────────────────────────────────────
  widget {
    group_definition {
      title            = "Resource Usage"
      layout_type      = "ordered"
      background_color = "green"

      widget {
        timeseries_definition {
          title       = "CPU Usage by Deployment"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "avg:kubernetes.cpu.usage.total{${local.namespace_filter}} by {kube_deployment}"
            display_type = "line"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Memory Usage by Deployment"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "avg:kubernetes.memory.usage{${local.namespace_filter}} by {kube_deployment}"
            display_type = "line"
          }
        }
      }
    }
  }

  # ── Row 3: APM Request Health ──────────────────────────────────────────────
  widget {
    group_definition {
      title            = "APM Request Health"
      layout_type      = "ordered"
      background_color = "vivid_blue"

      widget {
        timeseries_definition {
          title       = "Request Rate by Service"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:trace.fastapi.request.hits{${local.env_filter}} by {service}.as_rate()"
            display_type = "line"
          }

          request {
            q            = "sum:trace.servlet.request.hits{${local.env_filter}} by {service}.as_rate()"
            display_type = "line"
          }

          request {
            q            = "sum:trace.express.request.hits{${local.env_filter}} by {service}.as_rate()"
            display_type = "line"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Error Rate by Service"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:trace.fastapi.request.errors{${local.env_filter}} by {service}.as_rate()"
            display_type = "bars"
          }

          request {
            q            = "sum:trace.servlet.request.errors{${local.env_filter}} by {service}.as_rate()"
            display_type = "bars"
          }

          request {
            q            = "sum:trace.express.request.errors{${local.env_filter}} by {service}.as_rate()"
            display_type = "bars"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "p95 Latency by Service (ms)"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "p95:trace.fastapi.request{${local.env_filter}} by {service}"
            display_type = "line"
          }

          request {
            q            = "p95:trace.servlet.request{${local.env_filter}} by {service}"
            display_type = "line"
          }

          request {
            q            = "p95:trace.express.request{${local.env_filter}} by {service}"
            display_type = "line"
          }
        }
      }
    }
  }

  # ── Row 4: Async Processing (JMS Consumers) ───────────────────────────────
  widget {
    group_definition {
      title            = "Async Processing (JMS Consumers)"
      layout_type      = "ordered"
      background_color = "vivid_purple"

      widget {
        timeseries_definition {
          title       = "Fraud Scoring Rate"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:trace.fraud.score.hits{${local.env_filter}}.as_rate()"
            display_type = "line"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Fraud Scoring Errors"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:trace.fraud.score.errors{${local.env_filter}}.as_count()"
            display_type = "bars"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Notification Dispatch Rate"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:trace.alert.send.hits{${local.env_filter}}.as_rate()"
            display_type = "line"
          }
        }
      }
    }
  }

  # ── Row 5: Logs ────────────────────────────────────────────────────────────
  widget {
    group_definition {
      title            = "Logs"
      layout_type      = "ordered"
      background_color = "yellow"

      widget {
        timeseries_definition {
          title       = "Log Volume by Service"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            log_query {
              index        = datadog_logs_index.finance_app.name
              search_query = local.finance_log_filter
              compute_query {
                aggregation = "count"
              }
              group_by {
                facet = "service"
                limit = 10
                sort_query {
                  aggregation = "count"
                  order       = "desc"
                }
              }
            }
            display_type = "bars"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Error Logs by Service"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            log_query {
              index        = datadog_logs_index.finance_app.name
              search_query = "${local.finance_log_filter} status:error"
              compute_query {
                aggregation = "count"
              }
              group_by {
                facet = "service"
                limit = 10
                sort_query {
                  aggregation = "count"
                  order       = "desc"
                }
              }
            }
            display_type = "bars"
          }
        }
      }
    }
  }

  # ── Row 6: Database & Messaging ───────────────────────────────────────────
  # NOTE: These widgets will show "No Data" until DBM (postgres.d/conf.yaml,
  # dbm: true) and the ActiveMQ JMX Agent check are configured — the queries
  # themselves are correct and match the metrics DBM/ActiveMQ would emit.
  widget {
    group_definition {
      title            = "Database & Messaging"
      layout_type      = "ordered"
      background_color = "gray"

      widget {
        timeseries_definition {
          title       = "DB Query Latency p95 (ms)"
          title_size  = "16"
          title_align = "left"
          show_legend = false

          request {
            q            = "p95:postgresql.query.duration{db:ledger,${local.env_filter}} * 1000"
            display_type = "line"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Active DB Connections"
          title_size  = "16"
          title_align = "left"
          show_legend = false

          request {
            q            = "avg:postgresql.connections{db:ledger,${local.env_filter}}"
            display_type = "line"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "ActiveMQ Queue Depth by Queue"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "max:activemq.artemis.queue.message_count{${local.env_filter}} by {queue}"
            display_type = "line"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "ActiveMQ Consumer Count by Queue"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "min:activemq.artemis.queue.consumer_count{${local.env_filter}} by {queue}"
            display_type = "line"
          }
        }
      }
    }
  }

  # ── Row 7: Monitor & Synthetics Status ────────────────────────────────────
  widget {
    group_definition {
      title            = "Monitor & Synthetics Status"
      layout_type      = "ordered"
      background_color = "vivid_pink"

      widget {
        manage_status_definition {
          title            = "Finance Monitors"
          title_size       = "16"
          title_align      = "left"
          query            = "\"[Finance]\""
          summary_type     = "monitors"
          sort             = "status,desc"
          display_format   = "countsAndList"
          color_preference = "text"
        }
      }

      widget {
        manage_status_definition {
          title            = "Synthetics Status"
          title_size       = "16"
          title_align      = "left"
          query            = "\"[Synthetics] Finance\""
          summary_type     = "monitors"
          sort             = "status,desc"
          display_format   = "countsAndList"
          color_preference = "text"
        }
      }
    }
  }
}

# ── Dashboard B: Business Lead ───────────────────────────────────────────────
# Audience: Business stakeholders. SLO status, payment volume/health, fraud &
# risk exposure, and a rolled-up reliability/risk-signal summary.
resource "datadog_dashboard" "finance_business" {
  title       = "Finance App — ${var.cluster_name} : Business Lead"
  description = "Business Lead view of the Finance sample app: SLOs, payment volume/health, fraud & risk. Managed by Terraform — deploy/terraform/datadog/."
  layout_type = "ordered"
  # tags are restricted in this org to team: and ai: only

  # ── Row 1: Service Level Objectives ───────────────────────────────────────
  widget {
    group_definition {
      title            = "Service Level Objectives"
      layout_type      = "ordered"
      background_color = "purple"

      widget {
        service_level_objective_definition {
          title             = "Payment API Availability"
          title_size        = "16"
          title_align       = "left"
          view_type         = "detail"
          slo_id            = datadog_service_level_objective.payment_availability.id
          show_error_budget = true
          view_mode         = "overall"
          time_windows      = ["7d", "30d"]
        }
      }

      widget {
        service_level_objective_definition {
          title             = "Payment API Latency"
          title_size        = "16"
          title_align       = "left"
          view_type         = "detail"
          slo_id            = datadog_service_level_objective.payment_latency.id
          show_error_budget = true
          view_mode         = "overall"
          time_windows      = ["7d", "30d"]
        }
      }

      widget {
        service_level_objective_definition {
          title             = "Fraud Queue Consumer Availability"
          title_size        = "16"
          title_align       = "left"
          view_type         = "detail"
          slo_id            = datadog_service_level_objective.fraud_consumer_availability.id
          show_error_budget = true
          view_mode         = "overall"
          time_windows      = ["7d", "30d"]
        }
      }
    }
  }

  # ── Row 2: Payment Volume & Health ────────────────────────────────────────
  widget {
    group_definition {
      title            = "Payment Volume & Health"
      layout_type      = "ordered"
      background_color = "orange"

      widget {
        query_value_definition {
          title       = "Payments Initiated"
          title_size  = "16"
          title_align = "left"
          autoscale   = true
          precision   = 0

          request {
            q          = "sum:finance.payment.hits{${local.env_filter}}.as_count()"
            aggregator = "sum"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Payment p95 Latency (ms)"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "p95:finance.payment.duration{${local.env_filter}} / 1000000"
            display_type = "line"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Payment Success vs Failed"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:finance.payment.success{${local.env_filter}}.as_count()"
            display_type = "line"
          }

          request {
            q            = "sum:finance.payment.failed{${local.env_filter}}.as_count()"
            display_type = "line"
          }
        }
      }
    }
  }

  # ── Row 3: Fraud & Risk ────────────────────────────────────────────────────
  widget {
    group_definition {
      title            = "Fraud & Risk"
      layout_type      = "ordered"
      background_color = "vivid_orange"

      widget {
        timeseries_definition {
          title       = "Fraud Score Distribution"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:finance.fraud.hits{${local.env_filter}} by {score_bucket}"
            display_type = "bars"
          }
        }
      }

      widget {
        query_value_definition {
          title       = "High-Risk Transactions"
          title_size  = "16"
          title_align = "left"
          autoscale   = true
          precision   = 0

          request {
            q          = "sum:finance.fraud.hits{${local.env_filter},score_bucket:high}.as_count()"
            aggregator = "sum"
          }
        }
      }
    }
  }

  # ── Row 4: Reliability & Risk Signals ─────────────────────────────────────
  widget {
    group_definition {
      title            = "Reliability & Risk Signals"
      layout_type      = "ordered"
      background_color = "vivid_pink"

      widget {
        manage_status_definition {
          title            = "Finance Monitors"
          title_size       = "16"
          title_align      = "left"
          query            = "\"[Finance]\""
          summary_type     = "monitors"
          sort             = "status,desc"
          display_format   = "countsAndList"
          color_preference = "text"
        }
      }

      widget {
        manage_status_definition {
          title            = "Finance Security Signals (ASM / CWS / CSPM)"
          title_size       = "16"
          title_align      = "left"
          query            = "\"[Finance] ASM\" OR \"[Finance] CWS\" OR \"[Finance] CSPM\""
          summary_type     = "monitors"
          sort             = "status,desc"
          display_format   = "countsAndList"
          color_preference = "text"
        }
      }
    }
  }
}

# ── Dashboard C: Finance Analyst ─────────────────────────────────────────────
# Audience: Finance/operations analysts reconciling trades, payments, and
# batch settlement runs.
resource "datadog_dashboard" "finance_analyst" {
  title       = "Finance App — ${var.cluster_name} : Finance Analyst"
  description = "Finance Analyst view of the Finance sample app: trade/payment outcomes, currency & type breakdowns, fraud review queue, and settlement reconciliation. Managed by Terraform — deploy/terraform/datadog/."
  layout_type = "ordered"
  # tags are restricted in this org to team: and ai: only

  # ── Row 1: Trades — Successful vs Pending ─────────────────────────────────
  widget {
    group_definition {
      title            = "Trades — Successful vs Pending"
      layout_type      = "ordered"
      background_color = "blue"

      widget {
        query_value_definition {
          title       = "Successful Payments"
          title_size  = "16"
          title_align = "left"
          autoscale   = true
          precision   = 0

          request {
            q          = "sum:finance.payment.success{${local.env_filter}}.as_count()"
            aggregator = "sum"
          }
        }
      }

      widget {
        query_value_definition {
          title       = "Failed Payments"
          title_size  = "16"
          title_align = "left"
          autoscale   = true
          precision   = 0

          request {
            q          = "sum:finance.payment.failed{${local.env_filter}}.as_count()"
            aggregator = "sum"
          }
        }
      }

      widget {
        # Requires DBM enabled (finance.db.ledger.pending_count is the DBM
        # custom_queries metric defined in postgres.d/conf.yaml) to populate.
        query_value_definition {
          title       = "Pending Transactions"
          title_size  = "16"
          title_align = "left"
          autoscale   = true
          precision   = 0

          request {
            q          = "max:finance.db.ledger.pending_count{${local.env_filter}}"
            aggregator = "last"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Payments Over Time by Outcome"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:finance.payment.success{${local.env_filter}}.as_count()"
            display_type = "line"
          }

          request {
            q            = "sum:finance.payment.failed{${local.env_filter}}.as_count()"
            display_type = "line"
          }
        }
      }
    }
  }

  # ── Row 2: Payment Breakdown ───────────────────────────────────────────────
  widget {
    group_definition {
      title            = "Payment Breakdown"
      layout_type      = "ordered"
      background_color = "green"

      widget {
        # Depends on the finance.payment.hits filter fix (Part 3): grouping by
        # currency requires the metric to be computed from the payment.authorize
        # span, which carries the @payment.currency tag.
        timeseries_definition {
          title       = "Payment Volume by Currency"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:finance.payment.hits{${local.env_filter}} by {currency}"
            display_type = "bars"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Payment Volume by Type"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:finance.payment.hits{${local.env_filter}} by {transaction_type}"
            display_type = "bars"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Payment Duration p95"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "p95:finance.payment.duration{${local.env_filter}}"
            display_type = "line"
          }
        }
      }
    }
  }

  # ── Row 3: Fraud Review Queue ──────────────────────────────────────────────
  widget {
    group_definition {
      title            = "Fraud Review Queue"
      layout_type      = "ordered"
      background_color = "vivid_orange"

      widget {
        timeseries_definition {
          title       = "Fraud Score Distribution by Bucket"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:finance.fraud.hits{${local.env_filter}} by {score_bucket}"
            display_type = "bars"
          }
        }
      }

      widget {
        query_value_definition {
          title       = "High-Risk Transaction Count"
          title_size  = "16"
          title_align = "left"
          autoscale   = true
          precision   = 0

          request {
            q          = "sum:finance.fraud.hits{${local.env_filter},score_bucket:high}.as_count()"
            aggregator = "sum"
          }
        }
      }
    }
  }

  # ── Row 4: Settlement & Reconciliation ────────────────────────────────────
  widget {
    group_definition {
      title            = "Settlement & Reconciliation"
      layout_type      = "ordered"
      background_color = "gray"

      widget {
        timeseries_definition {
          title       = "Batch Records Processed by Job/Status"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:finance.batch.records_processed{${local.env_filter}} by {job_name,job_status}"
            display_type = "bars"
          }
        }
      }

      widget {
        query_value_definition {
          title       = "Ledger Commit Errors"
          title_size  = "16"
          title_align = "left"
          autoscale   = true
          precision   = 0

          request {
            q          = "sum:finance.ledger.commit.errors{${local.env_filter}}.as_count()"
            aggregator = "sum"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Ledger Commit Errors Over Time"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:finance.ledger.commit.errors{${local.env_filter}}.as_count()"
            display_type = "bars"
          }
        }
      }
    }
  }
}

# ── Dashboard D: Admin ────────────────────────────────────────────────────────
# Audience: Platform/security admins. Payment ops summary, security posture,
# operational health, and synthetic test status.
resource "datadog_dashboard" "finance_admin" {
  title       = "Finance App — ${var.cluster_name} : Admin"
  description = "Admin view of the Finance sample app: payment operations, security posture, operational health, and synthetic test status. Managed by Terraform — deploy/terraform/datadog/."
  layout_type = "ordered"
  # tags are restricted in this org to team: and ai: only

  # ── Row 1: Payment Operations Overview ────────────────────────────────────
  widget {
    group_definition {
      title            = "Payment Operations Overview"
      layout_type      = "ordered"
      background_color = "orange"

      widget {
        query_value_definition {
          title       = "Payments Initiated"
          title_size  = "16"
          title_align = "left"
          autoscale   = true
          precision   = 0

          request {
            q          = "sum:finance.payment.hits{${local.env_filter}}.as_count()"
            aggregator = "sum"
          }
        }
      }

      widget {
        query_value_definition {
          title       = "Payment Errors"
          title_size  = "16"
          title_align = "left"
          autoscale   = true
          precision   = 0

          request {
            q          = "sum:finance.payment.failed{${local.env_filter}}.as_count()"
            aggregator = "sum"
          }
        }
      }

      widget {
        query_value_definition {
          title       = "High-Risk Transactions"
          title_size  = "16"
          title_align = "left"
          autoscale   = true
          precision   = 0

          request {
            q          = "sum:finance.fraud.hits{${local.env_filter},score_bucket:high}.as_count()"
            aggregator = "sum"
          }
        }
      }
    }
  }

  # ── Row 2: Security Posture ────────────────────────────────────────────────
  widget {
    group_definition {
      title            = "Security Posture"
      layout_type      = "ordered"
      background_color = "vivid_pink"

      widget {
        manage_status_definition {
          title            = "Finance Security Signals (ASM / CWS / CSPM)"
          title_size       = "16"
          title_align      = "left"
          query            = "\"[Finance] ASM\" OR \"[Finance] CWS\" OR \"[Finance] CSPM\""
          summary_type     = "monitors"
          sort             = "status,desc"
          display_format   = "countsAndList"
          color_preference = "text"
        }
      }

      widget {
        timeseries_definition {
          title       = "Security Events Over Time"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            log_query {
              index        = datadog_logs_index.finance_app.name
              search_query = "source:(appsec OR runtime-security OR compliance-agent) ${local.env_filter}"
              compute_query {
                aggregation = "count"
              }
              group_by {
                facet = "service"
                limit = 10
                sort_query {
                  aggregation = "count"
                  order       = "desc"
                }
              }
            }
            display_type = "bars"
          }
        }
      }
    }
  }

  # ── Row 3: Operational Health ──────────────────────────────────────────────
  widget {
    group_definition {
      title            = "Operational Health"
      layout_type      = "ordered"
      background_color = "blue"

      widget {
        query_value_definition {
          title       = "Running Pods"
          title_size  = "16"
          title_align = "left"
          autoscale   = true
          precision   = 0

          request {
            q          = "sum:kubernetes.pods.running{${local.namespace_filter}}"
            aggregator = "last"
          }
        }
      }

      widget {
        query_value_definition {
          title       = "Pod Restarts (15m)"
          title_size  = "16"
          title_align = "left"
          autoscale   = true
          precision   = 0

          request {
            q          = "sum:kubernetes.containers.restarts{${local.namespace_filter}}.as_count()"
            aggregator = "sum"
          }
        }
      }

      widget {
        manage_status_definition {
          title            = "Finance Monitors"
          title_size       = "16"
          title_align      = "left"
          query            = "\"[Finance]\""
          summary_type     = "monitors"
          sort             = "status,desc"
          display_format   = "countsAndList"
          color_preference = "text"
        }
      }
    }
  }

  # ── Row 4: Synthetic Test Status ──────────────────────────────────────────
  widget {
    group_definition {
      title            = "Synthetic Test Status"
      layout_type      = "ordered"
      background_color = "vivid_purple"

      widget {
        manage_status_definition {
          title            = "Synthetics Status"
          title_size       = "16"
          title_align      = "left"
          query            = "\"[Synthetics] Finance\""
          summary_type     = "monitors"
          sort             = "status,desc"
          display_format   = "countsAndList"
          color_preference = "text"
        }
      }
    }
  }
}

# =============================================================================
# Synthetic Tests
# =============================================================================
# Seven API tests derived from real traffic patterns observed on env:staging.
# Sources:
#   - APM span aggregation: POST /api/v2/spans/analytics/aggregate
#   - Traffic generator: scripts/generate-traffic.py
#
# Observed baselines (p95, 2-hour window):
#   GET  /health                          →  < 6ms
#   GET  /v1/accounts/{id}/balance        → 16ms
#   POST /v1/payments                     → 24ms  (gateway)
#   POST /v1/payments                     → 16ms  (transaction-service)
#   POST /v1/accounts                     → 575ms (PostgreSQL insert, cold pool)
#
# Docs: https://docs.datadoghq.com/synthetics/api_tests/
# Terraform resource: https://registry.terraform.io/providers/DataDog/datadog/latest/docs/resources/synthetics_test
# =============================================================================

# ── Auth strategy for the authenticated tests below ───────────────
# payment_happy_path, balance_check, and payment_bad_payload each start with
# a "Login" api_step that authenticates against Keycloak directly (password
# grant, finance-trader test user) and extracts a fresh access token into
# {{ACCESS_TOKEN}} for use by later steps in the SAME test run. This avoids
# a static SYNTHETIC_BEARER_TOKEN global variable, which would need manual
# rotation every ~5 minutes (Keycloak's default access token lifetime) and
# would otherwise fail permanently between rotations.
#
# Similarly, balance_check and payment_happy_path each create their own
# fresh account (POST /internal/accounts) as an early step and extract its
# id into {{ACCOUNT_ID}}, instead of depending on a static account ID.
# account-service currently stores accounts in an in-memory map (see
# AccountService.java) that is wiped on every pod restart, so any
# hardcoded/static account ID would eventually 404 — creating a fresh one
# per test run makes these tests immune to that restart behaviour.
#
# Requires TF_VAR_keycloak_client_secret to be set (see variables.tf).

# ── 1. Health checks ─────────────────────────────────────────────────────────
# Most frequent route (500+ hits/h). One test per service entry point.
# Fast canary — if any of these fail, the service is down.

resource "datadog_synthetics_test" "health_gateway" {
  name    = "Finance Health Check — gateway-api"
  type    = "api"
  subtype = "http"
  status  = "live"

  request_definition {
    method = "GET"
    url    = "${local.synthetic_gateway_base}/health"
  }

  request_headers = {
    Accept = "application/json"
  }

  assertion {
    type     = "statusCode"
    operator = "is"
    target   = "200"
  }
  assertion {
    type     = "body"
    operator = "contains"
    target   = "ok"
  }
  assertion {
    type     = "responseTime"
    operator = "lessThan"
    target   = "2000"
  }

  locations = ["aws:eu-west-1"]

  options_list {
    tick_every = 60

    retry {
      count    = 1
      interval = 300
    }

    monitor_options {
      renotify_interval = 120
    }
  }

  tags = concat(local.common_tags, ["service:gateway-api", "synthetic_type:health"])
}

resource "datadog_synthetics_test" "health_account_service" {
  name    = "Finance Health Check — account-service"
  type    = "api"
  subtype = "http"
  status  = "live"

  request_definition {
    method = "GET"
    url    = local.synthetic_account_health_url
  }

  request_headers = {
    Accept = "application/json"
  }

  assertion {
    type     = "statusCode"
    operator = "is"
    target   = "200"
  }
  assertion {
    type     = "responseTime"
    operator = "lessThan"
    target   = "2000"
  }

  locations = ["aws:eu-west-1"]

  options_list {
    tick_every = 60

    retry {
      count    = 1
      interval = 300
    }

    monitor_options {
      renotify_interval = 120
    }
  }

  tags = concat(local.common_tags, ["service:account-service", "synthetic_type:health"])
}

resource "datadog_synthetics_test" "health_transaction_service" {
  name    = "Finance Health Check — transaction-service"
  type    = "api"
  subtype = "http"
  status  = "live"

  request_definition {
    method = "GET"
    url    = local.synthetic_transaction_health_url
  }

  request_headers = {
    Accept = "application/json"
  }

  assertion {
    type     = "statusCode"
    operator = "is"
    target   = "200"
  }
  assertion {
    type     = "responseTime"
    operator = "lessThan"
    target   = "2000"
  }

  locations = ["aws:eu-west-1"]

  options_list {
    tick_every = 60

    retry {
      count    = 1
      interval = 300
    }

    monitor_options {
      renotify_interval = 120
    }
  }

  tags = concat(local.common_tags, ["service:transaction-service", "synthetic_type:health"])
}

# ── 2. Payment happy path ──────────────────────────────────────────────────
# Most business-critical route. 93 hits/h, observed p95=24ms on gateway-api.
# Multi-step: Login → create test account → POST /v1/payments → GET /v1/payments/{id}

resource "datadog_synthetics_test" "payment_happy_path" {
  name    = "Finance Payment Flow — Happy Path (POST → GET)"
  type    = "api"
  subtype = "multi"
  status  = "live"

  api_step {
    name    = "Login — obtain access token"
    subtype = "http"

    request_definition {
      method             = "POST"
      url                = local.synthetic_keycloak_token_url
      body_type          = "application/x-www-form-urlencoded"
      body               = "grant_type=password&client_id=finance-gateway&username=bob.trader&password=${urlencode("Finance@2025!")}&client_secret=${urlencode(var.keycloak_client_secret)}"
      accept_self_signed = true
    }

    request_headers = {
      Content-Type = "application/x-www-form-urlencoded"
    }

    assertion {
      type     = "statusCode"
      operator = "is"
      target   = "200"
    }

    extracted_value {
      name = "ACCESS_TOKEN"
      type = "http_body"

      parser {
        type  = "json_path"
        value = "$.access_token"
      }
    }
  }

  api_step {
    name    = "Create test account"
    subtype = "http"

    request_definition {
      method = "POST"
      url    = local.synthetic_account_base
      body = jsonencode({
        ownerId  = "synthetic-payment-flow"
        tier     = "retail"
        currency = "EUR"
        balance  = 100.00
      })
    }

    request_headers = {
      Content-Type = "application/json"
      Accept       = "application/json"
    }

    assertion {
      type     = "statusCode"
      operator = "is"
      target   = "201"
    }

    extracted_value {
      name = "ACCOUNT_ID"
      type = "http_body"

      parser {
        type  = "json_path"
        value = "$.id"
      }
    }
  }

  api_step {
    name    = "POST /v1/payments — Initiate payment"
    subtype = "http"

    request_definition {
      method = "POST"
      url    = "${local.synthetic_gateway_base}/v1/payments"
      body = jsonencode({
        account_id       = "{{ACCOUNT_ID}}"
        amount           = 1.00
        currency         = "EUR"
        transaction_type = "payment"
      })
    }

    request_headers = {
      Content-Type  = "application/json"
      Accept        = "application/json"
      Authorization = "Bearer {{ACCESS_TOKEN}}"
    }

    assertion {
      type     = "statusCode"
      operator = "is"
      target   = "201"
    }
    assertion {
      type     = "responseTime"
      operator = "lessThan"
      target   = "5000"
    }

    extracted_value {
      name = "PAYMENT_ID"
      type = "http_body"

      parser {
        type  = "json_path"
        value = "$.payment_id"
      }
    }
  }

  api_step {
    name    = "GET /v1/payments/{{PAYMENT_ID}} — Verify record"
    subtype = "http"

    request_definition {
      method = "GET"
      url    = "${local.synthetic_transactions_base}/{{PAYMENT_ID}}"
    }

    request_headers = {
      Accept = "application/json"
    }

    assertion {
      type     = "statusCode"
      operator = "is"
      target   = "200"
    }
    assertion {
      type     = "responseTime"
      operator = "lessThan"
      target   = "2000"
    }
  }

  locations = ["aws:eu-west-1"]

  options_list {
    tick_every = 300

    retry {
      count    = 1
      interval = 1000
    }

    monitor_options {
      renotify_interval = 60
    }
  }

  tags = concat(local.common_tags, ["service:gateway-api", "synthetic_type:journey", "flow:payment"])
}

# ── 3. Balance check ──────────────────────────────────────────────────────────
# Highest-volume authenticated route: 70 hits/h, observed p95=16ms.

resource "datadog_synthetics_test" "balance_check" {
  name    = "Finance Balance Check — Authenticated GET"
  type    = "api"
  subtype = "multi"
  status  = "live"

  api_step {
    name    = "Login — obtain access token"
    subtype = "http"

    request_definition {
      method             = "POST"
      url                = local.synthetic_keycloak_token_url
      body_type          = "application/x-www-form-urlencoded"
      body               = "grant_type=password&client_id=finance-gateway&username=bob.trader&password=${urlencode("Finance@2025!")}&client_secret=${urlencode(var.keycloak_client_secret)}"
      accept_self_signed = true
    }

    request_headers = {
      Content-Type = "application/x-www-form-urlencoded"
    }

    assertion {
      type     = "statusCode"
      operator = "is"
      target   = "200"
    }

    extracted_value {
      name = "ACCESS_TOKEN"
      type = "http_body"

      parser {
        type  = "json_path"
        value = "$.access_token"
      }
    }
  }

  api_step {
    name    = "Create test account"
    subtype = "http"

    request_definition {
      method = "POST"
      url    = local.synthetic_account_base
      body = jsonencode({
        ownerId  = "synthetic-balance-check"
        tier     = "retail"
        currency = "EUR"
        balance  = 250.00
      })
    }

    request_headers = {
      Content-Type = "application/json"
      Accept       = "application/json"
    }

    assertion {
      type     = "statusCode"
      operator = "is"
      target   = "201"
    }

    extracted_value {
      name = "ACCOUNT_ID"
      type = "http_body"

      parser {
        type  = "json_path"
        value = "$.id"
      }
    }
  }

  api_step {
    name    = "GET /v1/accounts/{{ACCOUNT_ID}}/balance"
    subtype = "http"

    request_definition {
      method = "GET"
      url    = "${local.synthetic_gateway_base}/v1/accounts/{{ACCOUNT_ID}}/balance"
    }

    request_headers = {
      Accept        = "application/json"
      Authorization = "Bearer {{ACCESS_TOKEN}}"
    }

    assertion {
      type     = "statusCode"
      operator = "is"
      target   = "200"
    }
    assertion {
      type     = "responseTime"
      operator = "lessThan"
      target   = "200"
    }
  }

  locations = ["aws:eu-west-1"]

  options_list {
    tick_every = 60

    retry {
      count    = 1
      interval = 300
    }

    monitor_options {
      renotify_interval = 120
    }
  }

  tags = concat(local.common_tags, ["service:gateway-api", "synthetic_type:api", "flow:balance-check", "observed_p95:16ms"])
}

# ── 4. Unauthenticated rejection ──────────────────────────────────────────────
# Guards the auth middleware. A 200 here means auth is broken.

resource "datadog_synthetics_test" "unauthenticated_rejection" {
  name    = "Finance Auth — Unauthenticated Request Rejected (401)"
  type    = "api"
  subtype = "http"
  status  = "live"

  request_definition {
    method = "GET"
    url    = "${local.synthetic_gateway_base}/v1/accounts/acc-synthetic-test/balance"
  }

  request_headers = {
    Accept = "application/json"
    # Deliberately no Authorization header
  }

  assertion {
    type     = "statusCode"
    operator = "is"
    target   = "401"
  }
  assertion {
    type     = "responseTime"
    operator = "lessThan"
    target   = "500"
  }

  locations = ["aws:eu-west-1"]

  options_list {
    tick_every = 300

    retry {
      count    = 1
      interval = 300
    }

    monitor_options {
      renotify_interval = 120
    }
  }

  tags = concat(local.common_tags, ["service:gateway-api", "synthetic_type:security", "flow:auth-rejection"])
}

# ── 5. Bad payload rejection ──────────────────────────────────────────────────
# Validates input validation. A 500 here means unhandled exception.

resource "datadog_synthetics_test" "payment_bad_payload" {
  name    = "Finance Payment — Bad Payload Rejected (422)"
  type    = "api"
  subtype = "multi"
  status  = "live"

  api_step {
    name    = "Login — obtain access token"
    subtype = "http"

    request_definition {
      method             = "POST"
      url                = local.synthetic_keycloak_token_url
      body_type          = "application/x-www-form-urlencoded"
      body               = "grant_type=password&client_id=finance-gateway&username=bob.trader&password=${urlencode("Finance@2025!")}&client_secret=${urlencode(var.keycloak_client_secret)}"
      accept_self_signed = true
    }

    request_headers = {
      Content-Type = "application/x-www-form-urlencoded"
    }

    assertion {
      type     = "statusCode"
      operator = "is"
      target   = "200"
    }

    extracted_value {
      name = "ACCESS_TOKEN"
      type = "http_body"

      parser {
        type  = "json_path"
        value = "$.access_token"
      }
    }
  }

  api_step {
    name    = "POST /v1/payments — Bad payload"
    subtype = "http"

    request_definition {
      method = "POST"
      url    = "${local.synthetic_gateway_base}/v1/payments"
      body   = jsonencode({ not_a_valid_field = "synthetic-test" })
    }

    request_headers = {
      Content-Type  = "application/json"
      Accept        = "application/json"
      Authorization = "Bearer {{ACCESS_TOKEN}}"
    }

    assertion {
      type     = "statusCode"
      operator = "is"
      target   = "422"
    }
    assertion {
      type     = "statusCode"
      operator = "isNot"
      target   = "500"
    }
    assertion {
      type     = "responseTime"
      operator = "lessThan"
      target   = "500"
    }
  }

  locations = ["aws:eu-west-1"]

  options_list {
    tick_every = 300

    retry {
      count    = 1
      interval = 300
    }

    monitor_options {
      renotify_interval = 120
    }
  }

  tags = concat(local.common_tags, ["service:gateway-api", "synthetic_type:negative", "flow:payment-validation"])
}

# ── 6. Account not found ──────────────────────────────────────────────────────
# Guards against silent failures (missing record returning 200).

resource "datadog_synthetics_test" "account_not_found" {
  name    = "Finance Account — Not Found (404)"
  type    = "api"
  subtype = "http"
  status  = "live"

  request_definition {
    method = "GET"
    url    = "${local.synthetic_account_base}/acc-does-not-exist-synthetic"
  }

  request_headers = {
    Accept = "application/json"
  }

  assertion {
    type     = "statusCode"
    operator = "is"
    target   = "404"
  }
  assertion {
    type     = "statusCode"
    operator = "isNot"
    target   = "500"
  }
  assertion {
    type     = "responseTime"
    operator = "lessThan"
    target   = "500"
  }

  locations = ["aws:eu-west-1"]

  options_list {
    tick_every = 300

    retry {
      count    = 1
      interval = 300
    }

    monitor_options {
      renotify_interval = 120
    }
  }

  tags = concat(local.common_tags, ["service:account-service", "synthetic_type:negative", "flow:account-not-found"])
}

# ── 7. Account creation latency baseline ─────────────────────────────────────
# Tracks POST /v1/accounts over time. Observed p95=575ms — highest latency
# route in the app. Threshold set at 2000ms to catch regressions without
# false positives; tighten once connection pool is warmed.

resource "datadog_synthetics_test" "account_creation_latency" {
  name    = "Finance Account Creation — Latency Baseline (observed p95=575ms)"
  type    = "api"
  subtype = "http"
  status  = "live"

  # NOTE: field names must match account-service's Account model exactly
  # (ownerId/tier/currency/balance) — Jackson silently ignores unknown
  # fields and fills the rest with nulls/defaults instead of erroring, so a
  # mismatched body here would still return 201 while creating a malformed
  # record with a null ownerId and tier.
  request_definition {
    method = "POST"
    url    = local.synthetic_account_base
    body = jsonencode({
      ownerId  = "synthetic-test-user"
      tier     = "retail"
      currency = "EUR"
      balance  = 0.00
    })
  }

  request_headers = {
    Content-Type = "application/json"
    Accept       = "application/json"
  }

  assertion {
    type     = "statusCode"
    operator = "is"
    target   = "201"
  }
  assertion {
    type     = "responseTime"
    operator = "lessThan"
    target   = "2000"
  }

  locations = ["aws:eu-west-1"]

  options_list {
    tick_every = 600 # every 10 min — creates a real DB record each run

    retry {
      count    = 1
      interval = 1000
    }

    monitor_options {
      renotify_interval = 120
    }
  }

  tags = concat(local.common_tags, ["service:account-service", "synthetic_type:latency-baseline", "observed_p95:575ms"])
}

# =============================================================================
# Application Security Management (ASM) — Monitors & Signals
# =============================================================================
# These resources configure ASM alerting on top of the Agent-side threat
# detection enabled in datadog-agent.yaml (asm.threats.enabled: true).
#
# ASM works by instrumenting APM traces — no separate agent needed.
# Threats appear in Security > Application Security > Threats.
#
# Docs: https://docs.datadoghq.com/security/application_security/
# =============================================================================

# ── ASM: High-severity attack volume monitor ──────────────────────────────────
# Alert when the number of high-severity security signals spikes — indicates
# an active attack campaign against the finance API.
resource "datadog_monitor" "asm_high_severity_attacks" {
  name    = "[Finance] ASM — High-Severity Attack Volume Spike"
  type    = "log alert"
  message = <<-EOT
    High-severity AppSec signals are spiking on the Finance API.
    This may indicate an active attack campaign (SQLi, credential stuffing, etc.).

    Investigate in Security > Application Security > Threats:
    https://app.datadoghq.com/security/appsec

    Service: {{log.attributes.service}}
    Attack type: {{log.attributes.@appsec.type}}

    @finance-platform
  EOT

  query = "logs(\"source:appsec @severity:high env:${var.environment}\").index(\"*\").rollup(\"count\").by(\"service\").last(\"5m\") > 10"

  monitor_thresholds {
    critical = 10
    warning  = 5
  }

  notify_no_data    = false
  renotify_interval = 60
  tags              = concat(local.common_tags, ["security:appsec", "team:finance"])
}

# ── ASM: Authentication brute-force monitor ───────────────────────────────────
# Finance-specific business logic rule: alert on repeated login failures,
# which may indicate credential stuffing against the Keycloak-backed API.
resource "datadog_monitor" "asm_brute_force" {
  name    = "[Finance] ASM — Authentication Brute Force Detected"
  type    = "log alert"
  message = <<-EOT
    Repeated authentication failures detected on the Finance gateway.
    Possible credential stuffing or brute-force attack.

    Investigate in Security > Application Security > Threats:
    https://app.datadoghq.com/security/appsec

    @finance-platform
  EOT

  query = "logs(\"source:appsec @appsec.type:users.login.failure env:${var.environment}\").index(\"*\").rollup(\"count\").last(\"5m\") > 20"

  monitor_thresholds {
    critical = 20
    warning  = 10
  }

  notify_no_data    = false
  renotify_interval = 30
  tags              = concat(local.common_tags, ["security:appsec", "team:finance", "flow:auth"])
}

# =============================================================================
# Cloud Security Management (CSM) — Misconfigurations & CWS Monitors
# =============================================================================
# Monitors on top of the Agent-side CWS and CSPM enabled in
# datadog-agent.yaml (cws.enabled: true, cspm.enabled: true).
#
# CWS detects runtime threats (unexpected process exec, file writes, syscalls).
# CSPM audits K8s/cloud configs against CIS, PCI-DSS, SOC 2 benchmarks.
#
# Docs: https://docs.datadoghq.com/security/cloud_workload_security/
# Docs: https://docs.datadoghq.com/security/cloud_security_management/misconfigurations/
# =============================================================================

# ── CWS: Critical runtime security signal ────────────────────────────────────
# Alert immediately on any critical-severity CWS signal in the finance
# namespace — e.g. shell spawned inside a container, /etc modified, etc.
resource "datadog_monitor" "cws_critical_signal" {
  name    = "[Finance] CWS — Critical Runtime Security Signal"
  type    = "log alert"
  message = <<-EOT
    A critical Cloud Workload Security signal was detected in the Finance namespace.
    This may indicate active exploitation (container breakout, backdoor, etc.).

    Investigate immediately in Security > Cloud Security > Signals:
    https://app.datadoghq.com/security/signals

    Host: {{host.name}}
    Container: {{log.attributes.container.name}}
    Rule: {{log.attributes.agent.rule.name}}

    @finance-platform @pagerduty-finance-sev1
  EOT

  query = "logs(\"source:runtime-security @severity:critical kube_namespace:finance\").index(\"*\").rollup(\"count\").last(\"5m\") > 0"

  monitor_thresholds {
    critical = 0 # any occurrence is critical
  }

  notify_no_data    = false
  renotify_interval = 15
  tags              = concat(local.common_tags, ["security:cws", "team:finance"])
}

# ── CSPM: Critical misconfiguration count ────────────────────────────────────
# Alert when new critical misconfigurations are detected — e.g. privileged
# pod specs, exposed secrets in env vars, overly permissive RBAC.
resource "datadog_monitor" "cspm_critical_findings" {
  name    = "[Finance] CSPM — Critical Misconfiguration Detected"
  type    = "log alert"
  message = <<-EOT
    A critical cloud security misconfiguration was detected in the Finance cluster.
    Common causes: privileged pods, exposed secrets, insecure RBAC, missing network policies.

    Review in Security > Cloud Security > Misconfigurations:
    https://app.datadoghq.com/security/compliance

    Rule: {{log.attributes.@rules.name}}
    Resource: {{log.attributes.@resource_type}}

    @finance-platform
  EOT

  query = "logs(\"source:compliance-agent @severity:critical env:${var.environment}\").index(\"*\").rollup(\"count\").last(\"1h\") > 0"

  monitor_thresholds {
    critical = 0
  }

  notify_no_data    = false
  renotify_interval = 120
  tags              = concat(local.common_tags, ["security:cspm", "team:finance"])
}

# =============================================================================
# RUM Application — Finance Frontend Dashboard
# =============================================================================
# RUM is NOT managed by this Terraform module. It is created via a direct
# Datadog API call by 'make dem' (Digital Experience Monitoring), which also
# injects the resulting applicationId/clientToken into frontend-stub/index.html.
# This keeps RUM app lifecycle (create/delete, credential rotation) independent
# of the rest of the Datadog Terraform resources below.
#
# Docs: https://docs.datadoghq.com/real_user_monitoring/browser/
# See: Makefile 'dem'/'undem' targets, INSTRUMENTATION.md
# =============================================================================
