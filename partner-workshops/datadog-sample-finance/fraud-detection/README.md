# fraud-detection

Async fraud-scoring microservice for the Finance sample application.

Listens on `fraud.score.queue` via ActiveMQ Artemis (STOMP protocol), scores each inbound
transaction, and logs a structured JSON result. Written in Python 3.11.

The service runs cleanly with **zero Datadog configuration**. Every instrumentation block is
commented out and labelled so you can progressively enable each layer as a hands-on exercise.

---

## Datadog Instrumentation Notes

### Learning Progression

Work through these steps in order. Each step builds on the previous one, so do not skip ahead.

| Step | What to do | What you gain |
|------|-----------|---------------|
| **1** | Start the Datadog Agent container/DaemonSet alongside this service. Set `DD_API_KEY` in the Agent's environment. | Agent collects host-level metrics (CPU, memory, network). Confirm in Infrastructure > Host Map. |
| **2** | Copy `.env.example` to `.env` and fill in `DD_ENV`, `DD_SERVICE=fraud-detection`, `DD_VERSION`. Pass these into the container. | Unified Service Tagging active. All future telemetry is correlated under one service entity. |
| **3** | Run `make instrument` from the repo root — it applies `scripts/patches/fraud-detection.patch`, uncommenting the APM block in `main.py` (`from ddtrace import patch_all; patch_all()`). **This service has no `ddtrace` pip dependency, ever** — you also need Single Step Instrumentation (`make instrument`'s Step 2) plus the Datadog Operator installed in-cluster (`make deploy-k8s-dd`) and a redeploy, since SSI is what actually injects `ddtrace` into the pod. Uncommenting the code alone is not enough. | Auto-instrumented traces appear in APM > Services > fraud-detection. STOMP frames become `jms.consume` spans. |
| **4** | The same `make instrument` patch also uncomments `patch_logging()` in `main.py`. | Every log line gains `dd.trace_id` and `dd.span_id` fields. In Log Management, clicking a log opens the correlated trace and vice versa. |
| **5** | The same patch uncomments `from ddtrace import tracer` and the `with tracer.trace("fraud.score", ...)` block in `listener.py` (already tagged with `fraud.score_bucket`, `transaction.type`, `payment.currency`). | A dedicated `fraud.score` span appears inside each `jms.consume` trace. You can filter APM by `fraud.score_bucket:high` to see latency for risky transactions. |
| **6** | No DogStatsD in this app — `finance.fraud.score` / `finance.fraud.hits` are span-based metrics generated from the `fraud.score` span above (Module 7's `make tf-apply-dd`), not a separate metrics client. | The `finance.fraud.score` metric appears in Metrics Explorer, tagged by `fraud.score_bucket`. Build a dashboard widget: `avg:finance.fraud.score{fraud.score_bucket:high}`. |
| **7** | The same `make instrument` patch also uncomments `import ddtrace.profiling.auto` in `main.py`. | CPU and memory flame graphs appear in Profiler > fraud-detection. Correlate a CPU spike with the `fraud.score` span in the same trace. |
| **8** | No RUM applies to this backend-only service. If you have a frontend stub, add the Browser SDK there. | N/A for fraud-detection. |
| **9** | No direct DB connection in this service. DBM is configured on `account-service` and `transaction-service` (PostgreSQL). | Verify that `db.query` spans in those services show a "View in DBM" button in the APM trace view. |
| **10** | In `.env`, uncomment `DD_DATA_STREAMS_ENABLED=true`. In `listener.py`, uncomment the `set_consume_checkpoint(...)` call at the top of `on_message`. | DSM surfaces this consumer in the pipeline pathway map. Consumer lag on `fraud.score.queue` becomes visible. Alert when lag > N seconds to catch fraud-scoring backlogs before they delay payments. |
| **11** | Not applicable — Data Jobs Monitoring targets the `batch-processor` Spring Batch service. | N/A for fraud-detection. |
| **12** | Add a Synthetic API test that posts a mock message to the STOMP broker and verifies a scored log entry appears. Alternatively, test the health of the broker endpoint. | Continuous validation that the fraud-scoring pipeline is alive. Synthetic → APM trace correlation lets you see the full path of a synthetic-triggered message. |

---

## Quick Start (no Datadog)

```bash
cp .env.example .env
# Fill in STOMP_HOST, STOMP_USER, STOMP_PASS if different from defaults.
docker build -t fraud-detection:dev .
docker run --env-file .env fraud-detection:dev
```

The service connects to `activemq-artemis:61613` and waits for messages on `fraud.score.queue`.

---

## Sending a Test Message

Use the ActiveMQ Artemis web console (`http://localhost:8161`) or the STOMP CLI:

> **Credentials note:** `admin` / `admin` below only works against a standalone local broker running with
> default auth (e.g. `docker run activemq/artemis`). The actual deployed cluster uses the `artemis-password`
> secret from the `app-secrets` K8s Secret (`deploy/kubernetes/base/02-secrets.yaml`), which defaults to
> `artemis_dev_password`. To test against the deployed cluster, run
> `kubectl port-forward svc/activemq-artemis 8161:8161 -n finance` first and swap in that password
> (or read it via `kubectl get secret app-secrets -n finance -o jsonpath='{.data.artemis-password}' | base64 -d`).

```bash
# Install stomp CLI
pip install stomp.py

python - <<'EOF'
import stomp, json, time

conn = stomp.Connection([("localhost", 61613)])
conn.connect("admin", "admin", wait=True)  # local standalone broker only — see note above for the deployed cluster
conn.send(
    destination="/queue/fraud.score.queue",
    body=json.dumps({
        "transaction_id": "txn-test-001",
        "amount": 6500.00,
        "currency": "EUR",
        "transaction_type": "payment",
        "account_id": "acc-42"
    }),
    headers={"content-type": "application/json"},
)
time.sleep(0.5)
conn.disconnect()
print("Message sent.")
EOF
```

Expected log output (structured JSON):

```json
{
  "asctime": "2026-06-03T09:00:01",
  "levelname": "INFO",
  "name": "fraud_detection.listener",
  "message": "Fraud score computed",
  "transaction_id": "txn-test-001",
  "transaction.type": "payment",
  "payment.currency": "EUR",
  "fraud.score": 0.9,
  "fraud.score_bucket": "high",
  "messaging.destination": "fraud.score.queue",
  "jms.correlation_id": ""
}
```

---

## Project Structure

```
fraud-detection/
├── main.py          # Entry point: STOMP connection + listen loop
├── listener.py      # on_message handler, scoring orchestration, logging
├── scorer.py        # Deterministic fraud scoring stub
├── requirements.txt # Runtime + commented Datadog deps
├── Dockerfile       # python:3.11-slim image
├── .env.example     # All DD_* variables documented
└── README.md        # This file
```

---

## Tagging Reference

| Tag | Type | Example | Rationale |
|-----|------|---------|-----------|
| `fraud.score_bucket` | string | `low`, `medium`, `high` | Alert on high-risk transaction volume without cardinality explosion |
| `transaction.type` | string | `payment`, `refund` | Slice error rate by transaction category |
| `payment.currency` | string | `EUR`, `USD` | Regulatory / regional analysis |
| `messaging.destination` | string | `fraud.score.queue` | Identify which queue the span relates to |
| `jms.correlation_id` | string | `txn-8f3a2c` | Business-level correlation across async hops |

**HIGH-CARDINALITY WARNING:** Do not tag with `transaction_id`, `messaging.message_id`, or the raw
fraud score float. These are unbounded and will inflate your Datadog index.
Reference: https://docs.datadoghq.com/tagging/assigning_tags/#defining-tags

---

## Key References

| Topic | URL |
|-------|-----|
| Unified Service Tagging | https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging/ |
| APM — Python | https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/python/ |
| Custom instrumentation — Python | https://docs.datadoghq.com/tracing/trace_collection/custom_instrumentation/python/ |
| Log correlation — Python | https://docs.datadoghq.com/tracing/other_telemetry/connect_logs_and_traces/python/ |
| DogStatsD | https://docs.datadoghq.com/developers/dogstatsd/ |
| Continuous Profiler — Python | https://docs.datadoghq.com/profiler/enabling/python/ |
| Data Streams Monitoring — Python | https://docs.datadoghq.com/data_streams/python/ |
| Tagging best practices | https://docs.datadoghq.com/tagging/assigning_tags/ |
