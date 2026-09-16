# batch-processor — Finance Sample App

Spring Boot 3 / Spring Batch 5 / Java 17 service that runs two scheduled batch jobs:

| Job | Schedule | Purpose |
|---|---|---|
| `end-of-day-reconciliation` | Nightly 23:00 UTC | Reads settled transactions, compares against external ledger, writes discrepancy report |
| `monthly-statement-generation` | 1st of month, 01:00 UTC | Reads account history, generates PDF statement stubs per account |

All Datadog instrumentation is commented out. The service runs cleanly with no `DD_*` environment variables set.

---

## Running locally

```bash
# Copy and fill in environment variables
cp .env.example .env

# Build
./gradlew build

# Run (requires a PostgreSQL instance — see kubectl get pods -n finance # postgres-ledger runs in the finance namespace)
java -jar build/libs/batch-processor-*.jar

# Trigger a job manually (spring.batch.job.enabled=false disables auto-launch on startup —
# see BatchJobController.java for the real endpoints; there is no /actuator/batch/jobs/... path)
curl -X POST http://localhost:8083/jobs/reconciliation
curl -X POST http://localhost:8083/jobs/statement
```

---

## Datadog Instrumentation Notes

### Key architecture point: the Java agent is a JVM flag, not a code import

The Datadog Java agent (`dd-java-agent.jar`) attaches to the JVM via `-javaagent` in `JAVA_TOOL_OPTIONS`.
It auto-instruments Spring Batch, JDBC, and the scheduler without any changes to application code.
`dd-trace-api` (the optional Gradle dependency) is only needed for manual span creation and custom tags.

### Learning Progression

Work through these steps in order. Each step builds on the previous one.

---

#### Step 1 — Enable the Datadog Agent

Deploy the Datadog Agent DaemonSet with `make deploy-k8s-dd`.
Verify connectivity: `kubectl get pods -n finance` should show the Agent pods running.

The Agent receives traces, logs, and metrics from all services in the cluster.

---

#### Step 2 — Set Unified Service Tags

In `.env`, populate:
```
DD_ENV=staging
DD_SERVICE=batch-processor
DD_VERSION=$(git rev-parse --short HEAD)
DD_AGENT_HOST=datadog-agent
```

`DD_TRACE_SAMPLE_RATE=1.0` is already uncommented — batch jobs run infrequently and every run must be captured. Do not reduce this value for the batch-processor service.

Verify: every log line should contain `"service":"batch-processor"` (from `logback-spring.xml`).

---

#### Step 3 — Enable APM auto-instrumentation

The `dd-java-agent.jar` is already baked into the image — `Dockerfile` downloads it
unconditionally at build time (`ADD https://dtdg.co/latest-java-tracer /dd-java-agent.jar`)
so later steps (Data Jobs Monitoring, Continuous Profiler) don't require a rebuild.

All that's needed to actually attach it: in `.env`, uncomment the `JAVA_TOOL_OPTIONS`
block, then rebuild the image and restart the container.

What you see in APM:
- A `batch-processor` service entry appears under APM > Services
- Each Spring Batch `Job` appears as a root span
- Each `Step` appears as a child span of the job
- JDBC calls (reader SELECT, writer INSERT) appear as `jdbc.query` child spans of the step
- No code changes required

Docs: https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/java/

---

#### Step 4 — Enable log correlation

The `-Ddd.logs.injection=true` flag in `JAVA_TOOL_OPTIONS` (Step 3) activates log correlation automatically.

The agent injects `dd.trace_id` and `dd.span_id` into Logback's MDC before each log statement.
`logstash-logback-encoder` (already active in `logback-spring.xml`) includes all MDC fields in the JSON output.

To verify: trigger a job run, then in Log Management search for:
```
service:batch-processor @dd.trace_id:*
```
Click any log line. The "Trace" button should appear in the log detail panel, linking directly to the APM trace.

Docs: https://docs.datadoghq.com/tracing/other_telemetry/connect_logs_and_traces/java/

---

#### Step 5 — Enable custom spans for business-critical operations

In `build.gradle`, uncomment:
```gradle
compileOnly 'com.datadoghq:dd-trace-api:1.+'
```

In `DatadogJobListener.java`, uncomment the `beforeJob` and `afterJob` Datadog blocks.
These inject Finance-domain span tags: `job.name`, `job.id`, `job.status`, `job.records_processed`.

In `ReconciliationStepConfig.java`, uncomment the `StepExecutionListenerSupport` block.
This adds step-level tags: `job.step`, `job.batch_size`, `job.records_processed`.

Docs: https://docs.datadoghq.com/tracing/trace_collection/custom_instrumentation/java/

---

#### Step 6 — Enable DogStatsD custom metrics

In `build.gradle`, uncomment:
```gradle
implementation 'com.timgroup:java-statsd-client:3.1.0'
```

In `DatadogJobListener.afterJob()`, uncomment the DogStatsD block.
This emits `finance.batch.records_processed` tagged with `job.name`, `job.status`, and `env`.

Use this metric to build monitors:
- Alert when `finance.batch.records_processed` < 1000 for `end-of-day-reconciliation` (partial run)
- Alert when `job.status:FAILED` count > 0 (failed run)

Docs: https://docs.datadoghq.com/developers/dogstatsd/

---

#### Step 7 — Enable Continuous Profiler (high value for slow batch steps)

Add `-Ddd.profiling.enabled=true` to `JAVA_TOOL_OPTIONS` in `.env` (already present in the commented block).

What to look for in the Profiler:
- Navigate to APM > Profiler, filter by `service:batch-processor`
- Select a reconciliation job trace, click "View Profile" on a slow step span
- The flame graph shows which method is consuming CPU during that step
- Common findings in batch jobs: slow serialisation in the processor, GC pressure from large result sets, lock contention in the writer

For the statement job specifically: PDF generation is CPU-intensive. The profiler will show which account tier dominates CPU time — use this to identify optimisation priorities.

Docs: https://docs.datadoghq.com/profiler/

---

#### Step 8 — Add RUM to the frontend stub

Not applicable to batch-processor (no HTTP interface beyond Actuator).
See `frontend-stub/` for the Browser SDK integration.

---

#### Step 9 — Configure Database Monitoring for PostgreSQL

DBM is an agent-side feature — no code changes needed in batch-processor.

What DBM adds for batch jobs:
- Every JDBC query issued by the reader/writer appears in Databases > Query Samples
- Explain plans are captured automatically — no EXPLAIN in application code
- Slow reader queries (e.g. full-table scans on the `transactions` table) appear in Databases > Query Metrics sorted by total time
- The "View in DBM" button appears on `jdbc.query` APM spans, linking directly to the query sample

Ensure the `transactions` table has an index on `(status, settled_at)` — this is the WHERE clause used by the reconciliation reader.

See the root-level `deploy/` directory for the Agent `postgres.d/conf.yaml` configuration.

Docs: https://docs.datadoghq.com/database_monitoring/setup_postgres/selfhosted/

---

#### Step 10 — Enable Data Streams Monitoring for JMS

Enable if batch-processor publishes to JMS queues (e.g. `alert.queue` after statement generation).
Uncomment `DD_DATA_STREAMS_ENABLED=true` in `.env`.

The Java DSM SDK checkpoint call would be placed in `StatementJob.statementItemWriter()` before the JMS send.

Docs: https://docs.datadoghq.com/data_streams/java/

---

#### Step 11 — Enable Data Jobs Monitoring (primary step for batch-processor)

This is the most impactful step for a batch service. Data Jobs Monitoring provides:

| Signal | How to use it |
|---|---|
| Run history timeline | Audit trail for nightly reconciliation — compliance-relevant |
| Step duration per run | Detect regressions: did `reconciliation-step` suddenly take 3x longer? |
| Records processed per step | Alert when < N records written (partial run detection) |
| Failed run correlation | Click a failed run → "View Trace" → link to the JDBC slow query that caused it |

To enable:

1. Ensure dd-java-agent.jar is present in the image (Step 3)
2. Add `-Ddd.data.jobs.enabled=true` to `JAVA_TOOL_OPTIONS` (already in the commented block in `.env`)
3. Uncomment `compileOnly 'com.datadoghq:dd-trace-api:1.+'` in `build.gradle` (for custom tags)
4. In `DatadogJobListener.java`, uncomment both the `beforeJob` and `afterJob` Datadog blocks

After the next job run, navigate to APM > Data Jobs. You will see:
- `end-of-day-reconciliation` and `monthly-statement-generation` as separate job entries
- A run history timeline for each job
- Step-level duration breakdown within each run

Docs: https://docs.datadoghq.com/data_jobs/
Docs: https://docs.datadoghq.com/data_jobs/java/

---

#### Step 12 — Add Synthetic API tests

Add a Synthetic monitor for the Actuator health endpoint:
- `GET http://batch-processor:8083/actuator/health` — assert HTTP 200 and `status: UP`

See `synthetics/` in the root of the project for the Datadog Synthetic test definition.

Docs: https://docs.datadoghq.com/synthetics/

---

## Finance span tags reference

| Tag | Source | Example value |
|---|---|---|
| `job.name` | `DatadogJobListener.beforeJob` | `end-of-day-reconciliation` |
| `job.id` | `DatadogJobListener.beforeJob` | `42` |
| `job.env` | `DatadogJobListener.beforeJob` | `staging` |
| `job.status` | `DatadogJobListener.afterJob` | `COMPLETED` |
| `job.records_processed` | `DatadogJobListener.afterJob` | `15320` |
| `job.batch_size` | `ReconciliationStepConfig` listener | `100` |
| `job.step` | `ReconciliationStepConfig` listener | `reconciliation-step` |
| `account.tier` | `StatementJob` processor (manual) | `premium` |
| `payment.currency` | `StatementJob` processor (manual) | `EUR` |

> **High-cardinality warning:** Never tag with `transaction.id`, `account.id`, or raw `messaging.message_id` at span or metric level. These are unbounded value spaces that cause index bloat in Datadog. Use `job.name` and `account.tier` for aggregation.
> Docs: https://docs.datadoghq.com/tagging/assigning_tags/#defining-tags

---

## Key references

| Topic | URL |
|---|---|
| Unified Service Tagging | https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging/ |
| APM — Java | https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/java/ |
| Custom instrumentation — Java | https://docs.datadoghq.com/tracing/trace_collection/custom_instrumentation/java/ |
| Log correlation — Java | https://docs.datadoghq.com/tracing/other_telemetry/connect_logs_and_traces/java/ |
| Continuous Profiler | https://docs.datadoghq.com/profiler/ |
| Database Monitoring — PostgreSQL | https://docs.datadoghq.com/database_monitoring/setup_postgres/selfhosted/ |
| DBM + APM correlation | https://docs.datadoghq.com/database_monitoring/connect_dbm_and_apm/ |
| Data Streams Monitoring — Java | https://docs.datadoghq.com/data_streams/java/ |
| Data Jobs Monitoring | https://docs.datadoghq.com/data_jobs/ |
| Data Jobs — Java / Spring Batch | https://docs.datadoghq.com/data_jobs/java/ |
| DogStatsD | https://docs.datadoghq.com/developers/dogstatsd/ |
