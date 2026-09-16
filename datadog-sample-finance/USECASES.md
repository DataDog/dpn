# Meridian Financial — Workshop Use Cases

Three fault-injection scenarios for the hands-on lab, built on top of the `make tags` → `make dbm` →
`make instrument` → `make dem` → `make security` → `make tf-apply-dd` pipeline described in
[INSTRUMENTATION.md](./INSTRUMENTATION.md). Where that guide teaches *how to turn signals on*, this
doc is the **diagnosis phase**: each scenario injects a realistic incident into a running Meridian
Financial deployment and asks the room to find it using a specific Datadog capability.

Audience: workshop facilitators and partners running the on-site/online DPN Implementation Workshop
hands-on lab. Each scenario is off by default, independently toggleable, and reversible — safe to
demo forwards and backwards live.

**Prerequisite:** `make deploy-k8s` (app running) and `make instrument` applied — Scenario 1 needs it
for the `db.query` span to be visible in APM/DBM at all, and Scenario 3 needs it for the manual DSM
checkpoints that let `transaction-service` appear in the Data Streams pathway map (see Scenario 3's
"What's actually wrong" for why this isn't automatic). `make tf-apply-dd` is also recommended before
Scenario 2, since it ships the monitor that answers that scenario's discussion question.

---

## Use Case 1: Payments Are Slow and No One Knows Why

### Situation

Meridian Financial customers are reporting slow payment confirmations. Nothing crashed, nothing is
erroring — payments just take longer than they used to. Ask the room: where do you even start looking?

### What's actually wrong

`transaction-service`'s payment-velocity check (`ledger.velocity_check` span, in
`transaction-service/src/services/ledger.js`) queries `transactions` by `account_id` before every
payment write, relying on `idx_transactions_account_id`. `make scenario-1` drops that index directly
on the live `postgres-ledger` pod, turning the query into a full table scan on every single payment.

The `transactions` table is pre-seeded with ~300k backdated rows
(`deploy/kubernetes/base/infrastructure/postgres-init.yaml`, on first cluster boot only) specifically
so this full scan is actually slow enough to see — on a table with only the traffic-generator's own
volume (a few hundred rows), the same scan finishes in well under a millisecond and never shows up as
a visibly slow span.

### Datadog capability showcased

APM distributed tracing (a slow span appearing mid-trace), log-trace correlation, and Database
Monitoring (DBM) — specifically the APM ↔ DBM correlation link that lets you jump from a slow span
straight to the query's explain plan without touching the database directly.

### Trigger it

```bash
make scenario-1
```

Under the hood: `make scenario-1` runs `scripts/scenarios/scenario1-drop-index.sql`
(`DROP INDEX IF EXISTS idx_transactions_account_id;`) via
`kubectl exec -i -n finance statefulset/postgres-ledger -- psql -U finance -d ledger`, then touches
`.scenario-1-applied` to make the target idempotent. No rollout restart needed — this is a database
change, not a deployment change; the next payment request picks up the missing index immediately.

### What to look for in Datadog

- Generate payment traffic (the in-cluster `traffic-generator` already does this continuously).
- **APM → Traces** — filter `operation_name:ledger.velocity_check` or open any `POST /v1/payments`
  trace and look for an unusually slow `ledger.velocity_check` span (`db.instance:postgres-ledger`).
- Click the slow span → **View in DBM** — the query now shows a sequential scan on `transactions`
  where an index scan used to appear.
- **Databases → Query Metrics** for `postgres-ledger` — the velocity-check query's avg latency and
  total time both climb.

### Reverse it

```bash
make unscenario-1
```

Runs `scripts/scenarios/scenario1-restore-index.sql`
(`CREATE INDEX IF NOT EXISTS idx_transactions_account_id ON transactions (account_id);`) the same way,
and removes `.scenario-1-applied`.

---

## Use Case 2: The Nightly Reconciliation Is Failing Silently

### Situation

The nightly end-of-day reconciliation job on `batch-processor` reports **COMPLETED** every morning —
no exception, no failed run, nothing in an on-call inbox. But finance ops has started noticing
discrepancies between the ledger and the external settlement report. Ask the room: how do you catch a
job that says it succeeded but didn't actually do its job?

### What's actually wrong

`ReconciliationJob`'s `reconciliationItemReader`
(`batch-processor/src/main/java/com/example/finance/batch/job/ReconciliationJob.java`) reads settled
transactions for the day. `make scenario-2` sets `RECONCILIATION_SCENARIO_ENABLED=true`, which appends
`AND currency <> 'JPY'` to the reader's `WHERE` clause — silently excluding an entire settlement
currency from the run, framed as: the query was never updated after JPY settlements went live. The job
still completes with no error; only the record count drops (~20%, since `generate-traffic.py` picks a
currency uniformly at random from 5 options).

### Datadog capability showcased

Data Jobs Monitoring (Spring Batch step-level record counts — "your scheduler tells you it ran; Data
Jobs Monitoring tells you what it actually did"), plus the `finance.batch.records_processed` span
metric and the monitor built on it.

### Trigger it

```bash
make scenario-2
```

Under the hood: `kubectl set env deployment/batch-processor -n finance RECONCILIATION_SCENARIO_ENABLED=true`
followed by `kubectl rollout restart deployment/batch-processor -n finance`, then
`.scenario-2-applied` is touched. This only flips the env var and restarts the pod — it does not run
the job. Trigger an actual run with:

```bash
kubectl exec -n finance deploy/batch-processor -- curl -s -X POST localhost:8080/jobs/reconciliation
```

(or let `scripts/generate-traffic.py`'s `scenario_batch_job` fire it on its own schedule).

### What to look for in Datadog

- **APM → Data Jobs** — the `end-of-day-reconciliation` run shows status `COMPLETED` but
  `job.records_processed` is far lower than a normal run.
- The **`reconciliation_low_record_count`** monitor (`deploy/terraform/datadog/main.tf`, shipped by
  `make tf-apply-dd`) is built for exactly this: `avg(last_1h):avg:finance.batch.records_processed
  {job_name:end-of-day-reconciliation,...} < 5` (warning at 20, critical at 5) — this is the answer to
  "what monitor should have caught this." Note: those absolute thresholds were sized for a
  production-scale daily volume — at a workshop's own low traffic-generator throughput, a ~20% drop may
  not actually cross them within the session. Use `job.records_processed` in Data Jobs Monitoring as the
  live, always-reliable signal; treat the monitor as "here's the kind of alert you'd build," not
  something guaranteed to fire mid-demo.
- `batch-processor` logs for the run's `records.read`/`records.written` line.
- DBM — compare the reconciliation query's actual row count against the expected settled-transaction
  volume for the day.

### Reverse it

```bash
make unscenario-2
```

Runs `kubectl set env deployment/batch-processor -n finance RECONCILIATION_SCENARIO_ENABLED-` (unsets
the var) and `kubectl rollout restart deployment/batch-processor -n finance`, then removes
`.scenario-2-applied`.

---

## Use Case 3: The Fraud Queue Is Backing Up

### Situation

Fraud-scoring alerts are arriving 10–15 minutes after each transaction instead of near-real-time — the
risk window has already closed by the time a score comes back. The instinctive response is to scale up
`fraud-detection`, the consumer. Ask the room: is that actually the right fix?

### What's actually wrong

`make scenario-3` sets `FRAUD_QUEUE_DUPLICATE_FACTOR=3` on `transaction-service`. In
`transaction-service/src/routes/payments.js`, the fraud-scoring publish loops
`duplicateFactor` times per payment (default `1`, no behavior change) — at `3`, every payment now
triples its publish rate to `fraud.score.queue`. The **producer** is flooding the queue;
`fraud-detection` (the consumer) keeps processing at its normal, healthy rate. Scaling the consumer
would do nothing.

**DSM prerequisite:** `transaction-service` publishes over STOMP via the `stompit` library, which has
no dd-trace Node.js integration at all (there is no automatic STOMP instrumentation in dd-trace-js,
unlike account-service's JMS producer, which dd-trace-java instruments automatically). `make instrument`
now injects a manual DSM checkpoint (`tracer.dataStreamsCheckpointer.setProduceCheckpoint`, in
`transaction-service/src/messaging/producer.js`) and a manual consume checkpoint (`set_consume_checkpoint`,
in `fraud-detection/listener.py`) specifically to cover this gap. Without `make instrument` applied,
`transaction-service` never appears as a producer in the DSM pathway map for `fraud.score.queue` at
all — this scenario's DSM story does not work without it.

### Datadog capability showcased

Data Streams Monitoring (DSM) — "the only tool that distinguishes a producer problem from a consumer
problem on an async pipeline." Also relevant: APM and Deployment Tracking, since the throughput jump
lines up with the `transaction-service` rollout that injected it.

### Trigger it

```bash
make scenario-3
```

Under the hood: `kubectl set env deployment/transaction-service -n finance FRAUD_QUEUE_DUPLICATE_FACTOR=3`
followed by `kubectl rollout restart deployment/transaction-service -n finance`, then
`.scenario-3-applied` is touched.

### What to look for in Datadog

- Generate payment traffic, then open **Data Streams → pathway map** for `fraud.score.queue` — producer
  throughput climbs while consumer throughput on the `fraud-detection` side stays flat, i.e. a widening
  gap rather than a uniformly high queue.
- The **`fraud_queue_depth`** monitor (`deploy/terraform/datadog/main.tf`, shipped by `make tf-apply-dd`)
  fires on `activemq.artemis.queue.message_count{queue:_fraud.score.queue} > 100` (warning at 50). At a
  workshop's own traffic-generator throughput, `fraud-detection` easily keeps up even at 3x load, so
  actual queue *depth* may stay near 0 and this monitor may not fire live — depth alone hides a producer
  problem exactly when the consumer is healthy enough to mask it.
- The **`fraud_queue_producer_surge`** monitor (same file) exists for exactly that gap: a "change alert"
  on `activemq.artemis.queue.messages_added{queue:_fraud.score.queue}` (the production **rate**, not
  depth) — fires on a >50%/>100% jump vs. the prior 10 minutes, regardless of whether the consumer keeps
  up. This is the monitor that actually catches Scenario 3 live in a demo.
- **APM → Deployment Tracking** on `transaction-service` — the throughput change correlates with the
  rollout that set `FRAUD_QUEUE_DUPLICATE_FACTOR=3`, not with any change on `fraud-detection`.

### Reverse it

```bash
make unscenario-3
```

Runs `kubectl set env deployment/transaction-service -n finance FRAUD_QUEUE_DUPLICATE_FACTOR=1` and
`kubectl rollout restart deployment/transaction-service -n finance`, then removes
`.scenario-3-applied`.

---

## Reference

| Scenario | Toggle on | Toggle off | Mechanism | Datadog capability |
|---|---|---|---|---|
| 1 — Missing index | `make scenario-1` | `make unscenario-1` | `DROP`/`CREATE INDEX` on `postgres-ledger` via `kubectl exec` | APM traces, log correlation, DBM |
| 2 — Silent reconciliation failure | `make scenario-2` | `make unscenario-2` | `RECONCILIATION_SCENARIO_ENABLED` env var on `batch-processor` + rollout restart | Data Jobs Monitoring, Monitors, DBM |
| 3 — Fraud queue producer surge | `make scenario-3` | `make unscenario-3` | `FRAUD_QUEUE_DUPLICATE_FACTOR` env var on `transaction-service` + rollout restart | Data Streams Monitoring, APM, Deployment Tracking |

Each scenario is idempotent and tracked via its own sentinel file (`.scenario-N-applied`) — running
`make scenario-N` twice without reversing first is a no-op with a message telling you to run
`make unscenario-N` first. See [INSTRUMENTATION.md](./INSTRUMENTATION.md) for the instrumentation
pipeline these scenarios build on, and [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) if a scenario's
telemetry doesn't show up as expected.
