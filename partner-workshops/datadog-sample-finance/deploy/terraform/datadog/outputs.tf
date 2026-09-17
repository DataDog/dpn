# =============================================================================
# Finance Sample App — Datadog Terraform Outputs
# =============================================================================

output "log_index_name" {
  description = "Name of the Datadog log index created for the Finance app."
  value       = datadog_logs_index.finance_app.name
}

output "log_index_filter" {
  description = "Log filter query used by the Finance app index."
  value       = datadog_logs_index.finance_app.filter[0].query
}

output "dashboard_url" {
  description = "URL of the Finance app overview dashboard in Datadog."
  value       = "https://app.${var.datadog_site}/dashboard/${datadog_dashboard.finance_overview.id}"
}

output "dashboard_url_technical" {
  description = "URL of the Finance app Technical persona dashboard in Datadog."
  value       = "https://app.${var.datadog_site}/dashboard/${datadog_dashboard.finance_technical.id}"
}

output "dashboard_url_business" {
  description = "URL of the Finance app Business Lead persona dashboard in Datadog."
  value       = "https://app.${var.datadog_site}/dashboard/${datadog_dashboard.finance_business.id}"
}

output "dashboard_url_analyst" {
  description = "URL of the Finance app Finance Analyst persona dashboard in Datadog."
  value       = "https://app.${var.datadog_site}/dashboard/${datadog_dashboard.finance_analyst.id}"
}

output "dashboard_url_admin" {
  description = "URL of the Finance app Admin persona dashboard in Datadog."
  value       = "https://app.${var.datadog_site}/dashboard/${datadog_dashboard.finance_admin.id}"
}

# ── Monitors ────────────────────────────────────────────────────────────────

output "monitor_pod_restarts_id" {
  description = "ID of the pod restart monitor."
  value       = datadog_monitor.pod_restarts.id
}

output "monitor_error_rate_id" {
  description = "ID of the error rate (log alert) monitor."
  value       = datadog_monitor.error_rate.id
}

output "monitor_pods_not_running_id" {
  description = "ID of the pods-not-running monitor."
  value       = datadog_monitor.pods_not_running.id
}

output "monitor_payment_latency_id" {
  description = "ID of the payment p95 latency monitor."
  value       = datadog_monitor.payment_latency.id
}

output "monitor_payment_error_rate_id" {
  description = "ID of the payment error rate monitor."
  value       = datadog_monitor.payment_error_rate.id
}

output "monitor_fraud_queue_depth_id" {
  description = "ID of the fraud queue depth monitor."
  value       = datadog_monitor.fraud_queue_depth.id
}

output "monitor_fraud_queue_producer_surge_id" {
  description = "ID of the fraud queue producer rate surge monitor (catches Scenario 3 even when depth stays flat)."
  value       = datadog_monitor.fraud_queue_producer_surge.id
}

output "monitor_stuck_pending_transactions_id" {
  description = "ID of the stuck pending transactions monitor."
  value       = datadog_monitor.stuck_pending_transactions.id
}

output "monitor_ledger_commit_errors_id" {
  description = "ID of the ledger commit errors monitor."
  value       = datadog_monitor.ledger_commit_errors.id
}

# ── SLOs ────────────────────────────────────────────────────────────────────

output "slo_payment_availability_id" {
  description = "ID of the Payment API availability SLO (99.9% over 7d/30d)."
  value       = datadog_service_level_objective.payment_availability.id
}

output "slo_payment_latency_id" {
  description = "ID of the Payment API latency SLO (p95 < 2s, 99% of 7d)."
  value       = datadog_service_level_objective.payment_latency.id
}

output "slo_fraud_consumer_availability_id" {
  description = "ID of the fraud queue consumer availability SLO (99.5% of 7d)."
  value       = datadog_service_level_objective.fraud_consumer_availability.id
}

# ── Metrics ─────────────────────────────────────────────────────────────────

output "span_metrics" {
  description = "Span-based metrics generated from APM traces."
  value = {
    payment_hits               = datadog_spans_metric.payment_hits.name
    payment_duration           = datadog_spans_metric.payment_duration.name
    payment_success            = datadog_spans_metric.finance_payment_success.name
    payment_failed             = datadog_spans_metric.finance_payment_failed.name
    fraud_hits                 = datadog_spans_metric.fraud_hits.name
    fraud_score                = datadog_spans_metric.fraud_score.name
    batch_records              = datadog_spans_metric.batch_records.name
    notification_sent          = datadog_spans_metric.notification_sent.name
    notification_dispatch_time = datadog_spans_metric.notification_dispatch_time.name
    ledger_commit_errors       = datadog_spans_metric.finance_ledger_commit_errors.name
  }
}

output "log_metrics" {
  description = "Log-based metrics generated from structured logs."
  value = {
    error_count        = datadog_logs_metric.error_count.name
    payments_initiated = datadog_logs_metric.payments_initiated.name
  }
}

# ── RUM ────────────────────────────────────────────────────────────────────────────
# RUM is not created by this Terraform module — see 'make dem' / 'make undem'
# in the top-level Makefile, which creates the RUM application via a direct
# Datadog API call and stores its id/client_token in the gitignored
# .dem-state.json (not a Terraform output).
