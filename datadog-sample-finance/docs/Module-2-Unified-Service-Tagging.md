# Module 2 — Unified Service Tagging (`make tags`)

## Overview

`make tags` is the first instrumentation stage in the pipeline. It applies Unified Service Tagging
(UST) and log-trace correlation across all six Meridian Financial services via reversible unified
diff patches. Nothing here is automatic — every manifest ships with these blocks commented out
until this stage runs.

**Learning Objectives**
- Design a tag taxonomy grounded in real business services before instrumentation begins
- Understand what `env`/`service`/`version` actually enable, and why
- Apply UST + log injection to all six services and verify correlation end-to-end
- Recognize each language's log-injection mechanism (Python, Node, Java, Go all differ)

**Recommended Duration:** 45–60 minutes

**Prerequisites:** Module 1 complete — Meridian Financial and the Agent both running, nothing
instrumented yet.

## Section 1 — Tag Taxonomy

Every tag you'll ever want to filter a dashboard, monitor, or cost report by must be on the
workload from day one — retrofitting tags onto a live deployment is the most common cause of an
ungoverned, expensive Datadog deployment.

| Category | Key examples | Purpose |
|---|---|---|
| Unified Service Tagging | `service`, `env`, `version` | Trace-log-metric correlation — mandatory on every workload |
| Business Service | `business_service:payments` | Connects infra signals to business outcomes |
| Reserved (Datadog auto-assigned) | `host`, `device`, `source` | Auto-correlation across metrics/traces/logs |
| Notification routing | `slack_channel:finance-alerts` | Template variable in monitor messages: `@slack-{{slack_channel.name}}` |

Naming conventions: lowercase with hyphens, finite/enumerable values only (never a UUID, user ID,
or raw amount as a tag value — cardinality explosion), enforced org-wide via Tag Policies.

For Meridian Financial specifically, the six services already map cleanly to `service`:
`gateway-api`, `account-service`, `transaction-service`, `fraud-detection`,
`notification-service`, `batch-processor` — with `env:staging` and `version:latest` as the other
two UST dimensions.

## Section 2 — What `make tags` Actually Does

Two narrated steps, applied via patches under `scripts/patches/tags/`:

| Step | Target | Mechanism | What it enables |
|---|---|---|---|
| (a) UST | all 6 manifests | `ust-<service>.patch` | Uncomments `tags.datadoghq.com/env\|service\|version` pod labels + `DD_ENV`/`DD_SERVICE`/`DD_VERSION` env vars |
| (b) Log injection — Python | `gateway-api`, `fraud-detection` | `loginject-<service>.patch` | Uncomments `ddtrace.contrib.logging.patch` import + `patch_logging()` |
| (b) Log injection — Node | `transaction-service` | `loginject-transaction-service.patch` | Uncomments `logInjection: true` in the `dd-trace` init block |
| (b) Log injection — Java | `account-service`, `batch-processor` | `loginject-<service>.patch` | Uncomments `DD_LOGS_INJECTION=true` (dd-trace-java's Logback/Log4j2 MDC hook needs only this flag) |
| (b) Log injection — Go | `notification-service` | `loginject-notification-service.patch` | Uncomments manual `dd.trace_id`/`dd.span_id` injection into `slog` calls — Go has no automatic MDC-style hook |

> **Ordering matters for one service.** `notification-service`'s log injection reads
> `span.Context().TraceID()`/`SpanID()` off the `alert.send` span — a span that only exists once
> **Module 4's `make instrument`** has uncommented it. Running `make tags` alone leaves
> `notification-service` referencing an undefined `span` variable and it fails to build. Run
> `make instrument` before (or together with) `make tags` if you need Go's log injection working.

## Section 3 — Why It Matters

`DD_ENV`/`DD_SERVICE`/`DD_VERSION` (plus the matching pod labels) are what let Datadog group
traces/logs/metrics by service and correlate deploys via Deployment Tracking. Log injection
stitches structured JSON logs to APM traces — without it, "View Trace" from Log Management simply
isn't there, and logs and traces exist as two unrelated data sources.

## Section 4 — Workflow

```bash
make tags               # apply UST + log injection patches
make build               # rebuild the service images
make deploy-k8s          # re-applies the patched manifests — a bare rollout restart
                          # won't pick up new env vars/labels
```

> **EKS:** replace `make deploy-k8s` with `make deploy-k8s-eks`.

**Reverse it:**
```bash
make untag
make build               # then reload images (if needed) + make deploy-k8s
```

## Validate

Any trace or log should now carry `env:staging service:<name> version:latest`. In Log Explorer,
click any log line from a finance service — a **View Trace** button appears once `dd.trace_id` is
present.

## Practical Exercise

**Goal:** Apply UST + log injection to all six services and prove the log↔trace link works.

**Time:** 20–30 minutes

**Steps:**
1. `make tags && make build && make deploy-k8s`.
2. Confirm `DD_ENV`/`DD_SERVICE`/`DD_VERSION` are set on each pod: `kubectl exec -n finance
   deploy/gateway-api -- env | grep DD_`.
3. Open Log Explorer, filter `kube_namespace:finance service:transaction-service`, open any log
   line, and confirm **View Trace** appears.
4. Reverse it: `make untag && make build && make deploy-k8s` — confirm the button disappears
   again.

**Expected outcome:** Every service tagged with `env`/`service`/`version`, and a demonstrated,
reversible log→trace jump for at least one service.

## Resources & Next Steps

- Unified Service Tagging: https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging/
- Log-Trace Correlation: https://docs.datadoghq.com/tracing/other_telemetry/connect_logs_and_traces/
- Tag Policies: https://docs.datadoghq.com/monitors/settings/
- `sample/impl/INSTRUMENTATION.md` — `make tags` section, full patch-by-patch detail

**Next module**: [Module 3 — Database Monitoring (`make dbm`)](Module-3-Database-Monitoring.md)
