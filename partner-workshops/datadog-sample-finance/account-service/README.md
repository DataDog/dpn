# account-service

Java 17 / Spring Boot 3.x microservice for the Finance sample application.

Responsibilities: account CRUD, balance enquiry, JMS event production to `fraud.score.queue` and `alert.queue`.

The service runs cleanly with zero Datadog configuration. Every instrumentation block is commented out and labelled. Follow the Learning Progression below to enable each observability layer progressively.

---

## Datadog Instrumentation Notes

### Key principle — APM for Java is agent-based, not a code import

Unlike Python (`ddtrace`) or Node.js (`dd-trace`), Java APM does not require a `import` statement or an `init()` call in application code. The Datadog Java agent instruments the JVM at startup via a single JVM flag:

```
-javaagent:/dd-java-agent.jar
```

This one flag auto-instruments Spring MVC, JDBC, Spring JMS/ActiveMQ Artemis, and Logback MDC — with zero code changes. The `dd-trace-api` dependency is only needed if you want to write custom span annotations (`@Trace`) or set span tags programmatically.

Set the flag via `JAVA_TOOL_OPTIONS` (picked up automatically by any JVM process):

```bash
export JAVA_TOOL_OPTIONS="-javaagent:/dd-java-agent.jar -Ddd.service=account-service -Ddd.env=staging -Ddd.version=1.0.0"
```

Docs: https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/java/

---

## Learning Progression

Work through these steps in order. Each step builds on the previous one.

### Step 1 — Enable the Datadog Agent

Run the Datadog Agent as a DaemonSet (Kubernetes) alongside this service.

```bash
# Deploy with Datadog Agent
make deploy-k8s-dd

# Verify pods are running
kubectl get pods -n finance
```

Docs: https://docs.datadoghq.com/containers/kubernetes/

### Step 2 — Set Unified Service Tags

Set these environment variables on the `account-service` container before starting the agent. They propagate to all telemetry.

```bash
DD_ENV=staging
DD_SERVICE=account-service
DD_VERSION=1.0.0           # In CI: $(git rev-parse --short HEAD)
DD_AGENT_HOST=datadog-agent
```

Docs: https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging/

### Step 3 — Enable APM tracing (Java agent)

Add the `-javaagent` flag to `JAVA_TOOL_OPTIONS`. No code changes required.

1. Download the agent: `curl -Lo /dd-java-agent.jar https://dtdg.co/latest-java-tracer`
2. Set the env var (in the K8s Deployment — `deploy/kubernetes/base/services/account-service.yaml`):

```bash
JAVA_TOOL_OPTIONS="-javaagent:/dd-java-agent.jar -Ddd.service=account-service -Ddd.env=${DD_ENV} -Ddd.version=${DD_VERSION}"
```

3. Verify in Datadog: APM > Services > `account-service`

Auto-instrumented operations (no code changes needed):
- HTTP spans for every Spring MVC endpoint
- `db.query` spans for every JDBC/PostgreSQL statement
- `jms.produce` spans for every `JmsTemplate.send()` call

Docs: https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/java/

### Step 4 — Enable log correlation (trace_id injection)

Add `-Ddd.logs.injection=true` to `JAVA_TOOL_OPTIONS` (or set `DD_LOGS_INJECTION=true`).

The agent injects `dd.trace_id` and `dd.span_id` into the Logback MDC. The `logstash-logback-encoder` (already configured in `logback-spring.xml`) includes MDC fields in every JSON log line automatically.

In Datadog Log Management, click any log line from this service and select "View in APM" to jump to the parent trace.

Docs: https://docs.datadoghq.com/tracing/other_telemetry/connect_logs_and_traces/java/

### Step 5 — Add custom spans for business operations

Add `dd-trace-api` to `build.gradle` (commented out — see the file).

Then uncomment the `@Trace` annotations in:
- `AccountController.getBalance()` — `account.balance_check` span
- `AccountService.getBalance()` — child span for pure DB read latency
- `AccountService.createAccount()` — `account.create` root span

Add Finance domain tags to each span:
- `account.tier` → `retail | premium | corporate`
- `payment.currency` → `EUR | USD | GBP`

Docs: https://docs.datadoghq.com/tracing/trace_collection/custom_instrumentation/java/

### Step 6 — Emit custom DogStatsD metrics

Add `java-dogstatsd-client` to `build.gradle` (commented out).

Uncomment the `StatsDClient` blocks in `AccountService.java`:
- `finance.account.balance` — gauge, tagged by `account.tier`, `payment.currency`
- `finance.account.created` — counter, tagged by `account.tier`, `payment.currency`
- `finance.jms.produce.errors` — counter, tagged by `queue`, `error_type`

Metrics appear in Datadog Metrics Explorer under the `finance.*` namespace.

Docs: https://docs.datadoghq.com/developers/dogstatsd/

### Step 7 — Enable Continuous Profiler

Add `-Ddd.profiling.enabled=true` to `JAVA_TOOL_OPTIONS`. No code changes.

In Datadog: Continuous Profiler > `account-service` > CPU flame graph.

Use case: correlate high-CPU periods during `account.balance_check` or `account.create` with slow traces.

Docs: https://docs.datadoghq.com/profiler/enabling/java/

### Step 8 — Add RUM to the frontend stub

See `frontend-stub/` for the Browser SDK snippet (commented out). Finance-relevant RUM actions: `payment_form.submit`, `account_dashboard.load`.

Enable Session Replay with `defaultPrivacyLevel: 'mask-user-input'` to mask card numbers and account balances.

Docs: https://docs.datadoghq.com/real_user_monitoring/browser/

### Step 9 — Enable Database Monitoring (DBM) for PostgreSQL

DBM is Agent-side — see [INSTRUMENTATION.md's Step 9](../INSTRUMENTATION.md#step-9--database-monitoring-postgresql)
for the full setup (monitoring user, `pg_stat_statements`, Agent check config).

`account-service` is the primary JDBC writer to `postgres-ledger`. `dd-trace-java` automatically
sets `db.instance` and `peer.hostname` on its JDBC spans to match the DBM Agent config, so no
extra tagging is required here.

In Datadog: Databases > `postgres-ledger`. Click any query sample → "View Explain Plan". Click any `db.query` span in APM → "View in DBM".

### Step 10 — Enable Data Streams Monitoring (DSM) for JMS

DSM tracks end-to-end pipeline latency: `account-service → fraud.score.queue → fraud-detection`.

1. Set `DD_DATA_STREAMS_ENABLED=true` on the `account-service` container.
2. Uncomment the `DataStreamsCheckpointer.setProducerCheckpoint()` blocks in `PaymentEventProducer.java`.
3. Uncomment the consumer checkpoint in `fraud-detection` (`set_consume_checkpoint()`).

In Datadog: Data Streams > Pathway Map. You will see the full JMS pipeline with consumer lag metrics.

Key signals:
- Consumer lag on `fraud.score.queue` — detect fraud scoring backlog before it delays payments
- End-to-end latency — SLA breach alerting for async payment confirmation

Docs: https://docs.datadoghq.com/data_streams/java/

### Step 11 — Enable Data Jobs Monitoring (batch-processor only)

Not applicable to `account-service`. See `batch-processor/README.md` for Spring Batch instrumentation.

Docs: https://docs.datadoghq.com/data_jobs/java/

### Step 12 — Add Synthetic API tests

Create API tests in Datadog Synthetic Monitoring for:
- `GET /health` — liveness check, assert `status: ok`
- `GET /v1/accounts/{id}/balance` — assert response time < 200ms, status 200

In Datadog: Synthetic Monitoring > New Test > API Test.

Synthetic tests generate real APM traces — click "View in APM" from a Synthetic test result to see the full trace.

See `synthetics/` directory for example test definitions.

Docs: https://docs.datadoghq.com/synthetics/

---

## Finance Domain Tags Reference

| Tag | Type | Example | Purpose |
|-----|------|---------|---------|
| `account.tier` | string | `premium` | SLA-aware alerting — premium accounts get P1 |
| `payment.currency` | string | `EUR` | Regulatory and regional analysis |
| `transaction.type` | string | `payment` | Slice error rates by transaction category |
| `db.instance` | string | `postgres-ledger` | DBM ↔ APM correlation |
| `messaging.destination` | string | `fraud.score.queue` | Identify JMS queue in DSM pathway |
| `messaging.message_id` | string | `ID:broker-xxxx` | Producer↔consumer correlation only |

**WARNING — High cardinality:** Never use raw `accountId`, `userId`, `transactionId`, or `messageId` as span tag filtering dimensions. These have unbounded value spaces and will cause metric cardinality explosions. Use `messaging.message_id` for correlation lookups only, not as a tag key in custom metrics.

Docs: https://docs.datadoghq.com/tagging/assigning_tags/#defining-tags

---

## Local Development

```bash
# Check dependencies are running
kubectl get pods -n finance

# Run the service (no Datadog)
./gradlew bootRun

# Build fat JAR
./gradlew bootJar

# Build Docker image
docker build -t account-service:local .

# Run with Datadog agent (Step 3 onwards)
cp .env.example .env
# Edit .env: set DD_API_KEY, uncomment DD_* vars
make deploy-k8s-dd
```

## Project Structure

```
account-service/
  src/main/java/com/example/finance/account/
    AccountServiceApplication.java     # Spring Boot entry point
    controller/AccountController.java  # REST endpoints
    service/AccountService.java        # Business logic + DogStatsD hooks
    model/Account.java                 # Domain model
    messaging/PaymentEventProducer.java # JMS producer + DSM hooks
  src/main/resources/
    application.yml                    # Spring config (env-var driven)
    logback-spring.xml                 # Structured JSON logging
  build.gradle                         # Dependencies (dd-trace-api commented out)
  Dockerfile                           # eclipse-temurin:17-jre, JAVA_TOOL_OPTIONS hook
  .env.example                         # All DD_* vars documented
```
