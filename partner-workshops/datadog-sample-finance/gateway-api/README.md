# gateway-api

Public-facing REST gateway for the Finance sample application.
Built with Python 3.11 and FastAPI.

## Responsibilities

- Authentication middleware (stub)
- Route `/v1/payments` → transaction-service
- Route `/v1/accounts/{id}/balance` → account-service
- Structured JSON logging (python-json-logger)
- Health probe at `GET /health`

## Quick Start

```bash
cp .env.example .env
# Edit .env — set ACCOUNT_SERVICE_URL and TRANSACTION_SERVICE_URL
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8080 --reload
```

The service starts with **zero Datadog configuration**. All observability
code is commented out. Follow the Learning Progression below to enable
each layer incrementally.

## API Reference

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Liveness probe |
| POST | `/v1/payments` | Initiate a payment |
| GET | `/v1/accounts/{account_id}/balance` | Retrieve account balance |

### POST /v1/payments

Request body:

```json
{
  "amount": 250.00,
  "currency": "EUR",
  "account_id": "acc-0042"
}
```

Response (201):

```json
{
  "payment_id": "pay-3f8a1c2b9d0e",
  "status": "pending",
  "amount": 250.00,
  "currency": "EUR",
  "account_id": "acc-0042"
}
```

---

## Datadog Instrumentation Notes

All Datadog code lives in `main.py` inside clearly labelled
`# ── DATADOG INSTRUMENTATION ──` comment blocks. The blocks reference
the step numbers below so you can work through them in order.

**Important:** Never hardcode `DD_API_KEY` in any file. Inject it via
Docker Compose `env_file`, a Kubernetes Secret, or a secrets manager.

### What each block enables

| Step | Block location | What it unlocks |
|------|---------------|-----------------|
| 3 | Top of `main.py` | APM auto-instrumentation — traces in APM > Services |
| 4 | `.env.example` (`DD_LOGS_INJECTION`) | `dd.trace_id` injected into every JSON log line |
| 5 | Inside `initiate_payment` and `get_account_balance` | Named spans for `payment.authorize` and `account.balance_check` with Finance tags |
| 6 | Inside `initiate_payment` | `finance.payment.initiated` counter and `finance.payment.processing_time` histogram |
| 7 | Top of `main.py` (before other imports) | CPU/wall-clock flamegraphs in Continuous Profiler |

---

## Learning Progression

Work through these steps in order. Each step builds on the previous one.

1. **Enable the Datadog Agent sidecar / DaemonSet**
   Deploy the Datadog Agent (see `deploy/kubernetes/datadog/agent/datadog-agent.yaml`).
   Verify the Agent is healthy: `kubectl get pods -n finance`.
   Docs: https://docs.datadoghq.com/containers/kubernetes/

2. **Set Unified Service Tags**
   Copy `.env.example` to `.env`. Set `DD_ENV`, `DD_SERVICE`, and `DD_VERSION`.
   These three tags are the foundation of every Datadog correlation — traces,
   logs, metrics, and profiles will all carry them.
   Docs: https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging/

3. **Uncomment APM initialisation — verify traces in APM > Services**
   Run `make instrument` from the repo root — it applies `scripts/patches/gateway-api.patch`,
   which uncomments the `ddtrace` block at the top of `main.py` (`patch_all()` +
   `patch_logging()`) and the `payment.authorize`/`account.balance_check` custom spans.
   **This service has no `ddtrace` pip dependency, ever** — `make instrument`'s Step 2
   (Single Step Instrumentation) is what actually makes `ddtrace` importable, by injecting
   it into the pod via the Datadog Admission Controller. You also need the Datadog Operator
   installed in-cluster (`make deploy-k8s-dd`) and the pod redeployed for the webhook to
   mutate it — uncommenting the code alone is not enough.
   Send a test request: `curl -X POST http://localhost:8080/v1/payments ...`
   Navigate to APM > Services > gateway-api — you should see your first trace.
   Docs: https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/python/
   Docs: https://docs.datadoghq.com/tracing/trace_collection/automatic_instrumentation/single-step-apm/

4. **Uncomment log correlation — verify trace_id in Log Management**
   Set `DD_LOGS_INJECTION=true` in `.env`.
   Every JSON log line will now contain `dd.trace_id` and `dd.span_id`.
   In Log Management, open any log and click "View Trace" — it navigates
   directly to the originating APM trace.
   Docs: https://docs.datadoghq.com/tracing/other_telemetry/connect_logs_and_traces/

5. **Uncomment custom spans for critical business operations**
   In `main.py`: uncomment the `tracer.trace("payment.authorize", ...)` block
   inside `initiate_payment` and the `tracer.trace("account.balance_check", ...)`
   block inside `get_account_balance`.
   These spans appear as named operations in the APM flame graph, carry Finance
   domain tags (`transaction.type`, `payment.currency`, `account.tier`), and
   enable error-rate slicing by currency or account tier.
   Docs: https://docs.datadoghq.com/tracing/trace_collection/custom_instrumentation/python/

6. **Uncomment DogStatsD custom metrics — verify in Metrics Explorer**
   In `main.py`: uncomment the `statsd.increment` / `statsd.histogram` block.
   Also uncomment `datadog` in `requirements.txt`.
   Navigate to Metrics Explorer and search for `finance.payment.initiated`.
   Build a dashboard widget with `sum by {payment.currency}` to track payment
   volume by currency in real time.
   Metrics emitted:
   - `finance.payment.initiated` — counter (`transaction.type`, `payment.currency`, `status`)
   - `finance.payment.processing_time` — histogram in milliseconds (`payment.currency`)
   Docs: https://docs.datadoghq.com/developers/dogstatsd/

7. **Enable Continuous Profiler — validate flamegraphs**
   `import ddtrace.profiling.auto` is uncommented by the same `make instrument` patch as
   Step 3 (it must be the first import — already ordered correctly in `main.py`). Set
   `DD_PROFILING_ENABLED=true` in `.env`.
   In Continuous Profiler, filter by `service:gateway-api` and select the
   CPU timeline. Generate load (`ab -n 500 -c 10 ...`) then look for hot
   functions inside `initiate_payment` — correlate with slow payment traces.
   Docs: https://docs.datadoghq.com/profiler/enabling/python/

8. **Add RUM to the frontend stub**
   See `frontend-stub/` for the Browser SDK snippet (commented out).
   Finance-relevant RUM actions: `payment_form.submit`, `account_dashboard.load`.
   Enable Session Replay with `defaultPrivacyLevel: 'mask-user-input'` to
   automatically mask card numbers and account IDs.
   Docs: https://docs.datadoghq.com/real_user_monitoring/browser/

9. **Database Monitoring for PostgreSQL (DBM)**
   `gateway-api` does not query PostgreSQL directly — DBM is configured entirely on the Agent
   side against `postgres-ledger`. See [INSTRUMENTATION.md's Step 9](../INSTRUMENTATION.md#step-9--database-monitoring-postgresql)
   for the full setup. Note that `deploy/kubernetes/datadog/checks/postgres-check.yaml` serves two
   purposes in one file: the SQL prerequisites (monitoring user, `pg_stat_statements`) live in its
   **header comments**, while the Agent check config (`postgres.d/conf.yaml`) is the file's **body**.
   Once enabled, APM `db.query` spans from `account-service`/`transaction-service` will show a
   "View in DBM" button linking to the exact query plan.

10. **Enable Data Streams Monitoring (DSM) for the JMS/ActiveMQ pipeline**
    DSM is instrumented in transaction-service (producer) and fraud-detection
    (consumer). Set `DD_DATA_STREAMS_ENABLED=true` in each service's `.env`.
    In gateway-api, DSM context is propagated automatically via the httpx
    call to transaction-service once APM is active (Step 3).
    Docs: https://docs.datadoghq.com/data_streams/

11. **Enable Data Jobs Monitoring for the Spring Batch reconciliation job**
    Instrumented in `batch-processor` — see that service's README.
    From gateway-api, verify that the `batch.job.reconcile` span appears in
    APM and is tagged with `job.name:end-of-day-reconciliation`.
    Docs: https://docs.datadoghq.com/data_jobs/java/

12. **Add Synthetic API tests for /health and /v1/payments**
    See `synthetics/` for test definitions.
    The `/health` Synthetic test provides an always-on canary; the
    `/v1/payments` test exercises the full payment path on a schedule and
    injects a Synthetic trace that appears in APM alongside real traffic.
    Docs: https://docs.datadoghq.com/synthetics/

---

## Finance Domain Span Tags

| Tag | Type | Example | Rationale |
|-----|------|---------|-----------|
| `transaction.type` | string | `payment` | Slice error rates by transaction category |
| `payment.currency` | string | `EUR` | Regulatory / regional analysis |
| `account.tier` | string | `premium` | SLA-aware alerting |
| `http.route` | string | `/v1/payments/{id}` | Normalised route — avoids high cardinality |

> **High-cardinality warning:** `payment_id`, `account_id`, and raw `amount`
> values are **not** safe as span tags — their value spaces are unbounded.
> Store them in structured log records (bounded volume) and correlate via
> `dd.trace_id`. Reference: https://docs.datadoghq.com/tagging/assigning_tags/#defining-tags

## Key References

| Topic | URL |
|-------|-----|
| APM — Python | https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/python/ |
| Custom instrumentation — Python | https://docs.datadoghq.com/tracing/trace_collection/custom_instrumentation/python/ |
| Continuous Profiler — Python | https://docs.datadoghq.com/profiler/enabling/python/ |

For general Datadog docs, see [INSTRUMENTATION.md's Key references](../INSTRUMENTATION.md#key-references).
