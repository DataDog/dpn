# Finance App — Datadog Terraform Configuration

Manages all Datadog observability resources for the Finance sample app as code.

## What is provisioned

| Resource | Description |
|---|---|
| `datadog_logs_index.finance_app` | Dedicated log index with 15-day retention, filtered to `kube_cluster_name:finance-app kube_namespace:finance` |
| `datadog_logs_index_order.finance_app` | Places the finance index before `main` so logs are routed correctly |
| `datadog_logs_pipeline.finance_app` | Parsing pipeline: JSON parse → status remap → service remap → trace ID link → finance attribute promotion |
| `datadog_monitor.pod_restarts` | Alerts when any finance pod restarts > 3 times in 15 min |
| `datadog_monitor.error_rate` | Alerts when error log rate > 20/min for any service |
| `datadog_monitor.pods_not_running` | Alerts when running pod count drops below 8 |
| `datadog_dashboard.finance_overview` | Overview dashboard: pod health, CPU/memory, log volume, error rate |

## Prerequisites

This module talks only to the Datadog API — it does **not** require a running cluster.
You can apply it independently of where (or whether) the app is deployed.

A Datadog account plus `DD_API_KEY` / `DD_APP_KEY` set in the repo-root `.env` (see the
top-level README) — the single source of truth on every environment, local or AWS EKS alike.
`make tf-plan-dd` / `make tf-apply-dd` / `make tf-destroy-dd` read these directly from `.env`
and export the `TF_VAR_*` keys themselves; no separate export step is needed.

> `make tf-apply-aws` also creates empty `finance-app/<environment>/dd-api-key` / `dd-app-key`
> secrets in AWS Secrets Manager. This Terraform module does not read them — they're reserved
> for other AWS-side integrations (see `deploy/terraform/aws/variables.tf`), not for
> `tf-apply-dd`/`tf-plan-dd`/`tf-destroy-dd`. Populate `.env` instead.

## Usage

The API/App keys must be provided as `TF_VAR_datadog_api_key` / `TF_VAR_datadog_app_key`
environment variables (never in `staging.tfvars`). `make tf-plan-dd` / `make tf-apply-dd` /
`make tf-destroy-dd` resolve and export these from the repo-root `.env` automatically —
identically on local and AWS EKS.

```bash
# 1. Copy and review variables (first time only). Set datadog_site to match your org.
cp staging.tfvars.example staging.tfvars

# 2. Plan and apply. DD_API_KEY / DD_APP_KEY are read from the repo-root .env
#    automatically by these targets — no export step needed.
make tf-plan-dd
make tf-apply-dd
```

> **Local log-index caveat:** the log index filters on `kube_cluster_name:finance-app`.
> A local cluster usually reports a different cluster name, so local logs may not route into
> the dedicated index. The monitors, dashboard, and synthetics still work.
> **RUM is not created by this module** — it's created independently by `make dem`
> (a direct Datadog API call, not Terraform). `make dem` and `make tf-apply-dd` have no
> dependency on each other for RUM specifically.

Makefile targets:
```bash
make tf-plan-dd    # terraform plan for Datadog resources
make tf-apply-dd   # terraform apply for Datadog resources
make tf-destroy-dd # destroy all Datadog resources
```

## Key references

| Topic | URL |
|---|---|
| Datadog Terraform provider | https://registry.terraform.io/providers/DataDog/datadog/latest/docs |
| Log indexes | https://docs.datadoghq.com/logs/log_configuration/indexes/ |
| Log pipelines | https://docs.datadoghq.com/logs/log_configuration/pipelines/ |
| Monitors | https://docs.datadoghq.com/monitors/ |
| Dashboards | https://docs.datadoghq.com/dashboards/ |
