# Module 7 — Dashboards, Monitors & the Diagnosis Lab (`make tf-apply-dd`)

## Overview

`make tf-apply-dd` applies the Terraform-managed Datadog resources — dashboard, monitors, SLOs,
synthetics, log pipeline — that turn the raw telemetry from Modules 2–6 into something a team
actually watches day to day. Once applied, this module's second half is the **diagnosis lab**:
three fault-injection scenarios that inject a realistic incident into the running deployment and
ask the room to find it using a specific Datadog capability, without being told which one up
front.

**Learning Objectives**
- Apply the Terraform-managed dashboard, monitors, SLOs, and synthetic tests
- Diagnose three realistic incidents live, using the exact capability that catches each one
- Understand why a monitor's absolute thresholds can fail to fire at demo scale even when the
  underlying signal is genuinely correct

**Recommended Duration:** 1.5–2 hours (Terraform apply ~10 min; the diagnosis lab is the bulk)

**Prerequisites:** Modules 2–4 complete (`make tags`, `make dbm`, `make instrument`) — the lab's
three scenarios each depend on a specific earlier module being in place, called out per scenario
below.

## Section 1 — Applying the Terraform Resources

```bash
make tf-apply-dd   # DD_API_KEY / DD_APP_KEY are read from .env automatically
```

| Resource | What it is |
|---|---|
| Log index `finance-logs` | 15-day retention, `kube_namespace:finance` filter |
| Log pipeline | JSON parser + trace ID remapper + service remapper |
| Span-based metrics (`finance.payment.hits`, `finance.payment.duration`, `finance.fraud.hits`, `finance.batch.records_processed`, …) | Generated from the custom spans in Module 4 — no DogStatsD anywhere in this app |
| `finance.logs.errors` | Logs metric — error count by service |
| 7+ monitors | Pod restarts, error rate, payment latency, payment errors, fraud queue depth + producer surge, stuck transactions, pods not running, reconciliation record count |
| 3 SLOs | Payment availability (99.9%), payment latency (99%), fraud consumer (99.5%) |
| Dashboard | Finance App overview (APM, span-based metrics, DBM, ActiveMQ) |
| 7 Synthetic API tests | Health, payment happy path, balance check, auth rejection, bad payload, account-not-found, latency baseline |
| 4 Security monitors | ASM high-severity attacks, ASM brute force, CWS critical signal, CSPM critical findings |

**Not RUM** — RUM is created and owned entirely by Module 5's `make dem`.

**Reverse it:**
```bash
make tf-destroy-dd     # WARNING: deletes the log index (and all indexed logs), monitors, dashboard, SLOs
```

**Validate:** Dashboards → search `Finance App`.

## Section 2 — The Diagnosis Lab

Three fault-injection scenarios, each off by default, independently toggleable, and reversible —
safe to demo forwards and backwards live. Trigger with `make scenario-N`, reverse with
`make unscenario-N`.

### Scenario 1 — Payments Are Slow and No One Knows Why

**Situation:** Meridian Financial customers report slow payment confirmations. Nothing crashed,
nothing is erroring — payments just take longer than they used to.

**What's actually wrong:** `transaction-service`'s payment-velocity check
(`ledger.velocity_check` span, Module 3's DBM subject) queries `transactions` by `account_id`,
relying on `idx_transactions_account_id`. `make scenario-1` drops that index directly on the live
database, turning the query into a full table scan on every payment.

> **Depends on Module 3 (DBM) and the seed data.** The `transactions` table is pre-seeded with
> ~300k backdated rows on first cluster boot specifically so this full scan is actually slow
> enough to see — on a table with only the traffic generator's own volume (a few hundred rows),
> the same scan finishes in well under a millisecond and never shows up as a visibly slow span.

**Capability showcased:** APM distributed tracing, log-trace correlation, and the APM ↔ DBM
correlation link (Module 3) that jumps from a slow span straight to the query's explain plan.

**Trigger:** `make scenario-1` (drops the index via `kubectl exec` — no rollout restart needed,
the next payment picks up the missing index immediately). **Reverse:** `make unscenario-1`.

**What to look for:**
- APM → Traces — filter `operation_name:ledger.velocity_check`, look for an unusually slow span.
- Click the slow span → **View in DBM** — a sequential scan now appears where an index scan used
  to.
- Databases → Query Metrics for `postgres-ledger` — avg latency and total time both climb.

### Scenario 2 — The Nightly Reconciliation Is Failing Silently

**Situation:** `batch-processor`'s nightly reconciliation job reports **COMPLETED** every
morning — no exception, nothing in an on-call inbox. But finance ops has started noticing
discrepancies between the ledger and the external settlement report.

**What's actually wrong:** `make scenario-2` appends `AND currency <> 'JPY'` to the
reconciliation reader's `WHERE` clause — silently excluding an entire settlement currency,
framed as: the query was never updated after JPY settlements went live. The job still completes
with no error; only the record count drops (~20%, since traffic is generated with currency
picked uniformly at random from 5 options).

**Capability showcased:** Data Jobs Monitoring — "your scheduler tells you it ran; Data Jobs
Monitoring tells you what it actually did" — plus the `finance.batch.records_processed` span
metric and the monitor built on it.

**Trigger:** `make scenario-2` (flips an env var + rollout restart; does not itself run the job —
trigger a run via `kubectl exec -n finance deploy/batch-processor -- curl -s -X POST
localhost:8080/jobs/reconciliation`, or let the traffic generator's own scheduled batch scenario
fire it). **Reverse:** `make unscenario-2`.

**What to look for:**
- APM → Data Jobs — the run shows `COMPLETED` but `job.records_processed` is far lower than
  normal.
- The `reconciliation_low_record_count` monitor exists for exactly this — but its absolute
  thresholds were sized for production-scale daily volume. **At a workshop's own low
  traffic-generator throughput, a ~20% drop may not actually cross those thresholds within the
  session.** This is the point worth making explicitly: `job.records_processed` in Data Jobs
  Monitoring is the live, always-reliable signal; the monitor is "here's the kind of alert you'd
  build in production," not something guaranteed to fire mid-demo.
- `batch-processor` logs for the run's `records.read`/`records.written` line.

### Scenario 3 — The Fraud Queue Is Backing Up

**Situation:** Fraud-scoring alerts arrive 10–15 minutes after each transaction instead of
near-real-time — the risk window has already closed. The instinctive response is to scale up
`fraud-detection`, the consumer. Ask the room: is that actually the right fix?

**What's actually wrong:** `make scenario-3` triples `transaction-service`'s publish rate to
`fraud.score.queue` (`FRAUD_QUEUE_DUPLICATE_FACTOR=3`). The **producer** is flooding the queue;
`fraud-detection` keeps processing at its normal, healthy rate. Scaling the consumer would do
nothing.

> **Depends entirely on Module 4's DSM manual-checkpoint fix.** `transaction-service` publishes
> over STOMP, which dd-trace Node.js does not auto-instrument at all. Without the manual
> `setProduceCheckpoint` checkpoint from Module 4, `transaction-service` never appears as a
> producer in the DSM pathway map — this scenario's story does not work without that module
> already applied.

**Capability showcased:** Data Streams Monitoring — "the only tool that distinguishes a producer
problem from a consumer problem on an async pipeline." Also relevant: APM Deployment Tracking,
since the throughput jump lines up with the `transaction-service` rollout that injected it.

**Trigger:** `make scenario-3`. **Reverse:** `make unscenario-3`.

**What to look for:**
- Data Streams → pathway map for `fraud.score.queue` — producer throughput climbs while consumer
  throughput on `fraud-detection` stays flat: a widening gap, not a uniformly high queue.
- The `fraud_queue_depth` monitor (`message_count > 100`) may **not** fire at workshop traffic
  scale — `fraud-detection` easily keeps up even at 3x load, so actual queue depth stays near 0.
  Depth alone hides a producer problem exactly when the consumer is healthy enough to mask it.
- The `fraud_queue_producer_surge` monitor exists for exactly that gap — a change alert on the
  production **rate** (`messages_added`), not depth, firing on a >50%/>100% jump vs. the prior 10
  minutes regardless of whether the consumer keeps up. **This is the monitor that actually catches
  Scenario 3 live in a demo.**
- APM → Deployment Tracking on `transaction-service` — the throughput change correlates with its
  own rollout, not any change on `fraud-detection`.

## Practical Exercise

**Goal:** Run all three scenarios live, diagnose each using the specific capability that catches
it (not by being told the answer), then reverse all three.

**Time:** 60–75 minutes

**Steps:**
1. Confirm Modules 3 and 4 are applied (Scenario 1 needs DBM + seed data; Scenario 3 needs the
   DSM checkpoint).
2. Run Scenario 1. Without looking at this doc, find the slow query using only APM + DBM. Then
   reverse it.
3. Run Scenario 2. Trigger a reconciliation run, and find the record-count drop using Data Jobs
   Monitoring — note whether the monitor actually fired at your traffic volume, and why or why
   not. Then reverse it.
4. Run Scenario 3. Open the DSM pathway map before checking either monitor, and identify the
   producer/consumer asymmetry visually first. Then check both monitors and note which one
   actually fired. Then reverse it.

**Expected outcome:** All three incidents diagnosed using the intended capability, a clear
explanation of *why* the depth monitor and the low-record-count monitor might not fire at demo
scale even though the underlying incident is real, and a clean reversal of all three scenarios
plus the Terraform resources if this is the end of the session.

## Resources & Next Steps

- Synthetic Monitoring: https://docs.datadoghq.com/synthetics/
- Synthetic → APM correlation: https://docs.datadoghq.com/synthetics/apm/
- Generate metrics from spans: https://docs.datadoghq.com/tracing/trace_pipeline/generate_metrics/
- `sample/impl/USECASES.md` — full facilitator script for all three scenarios (situation,
  mechanism, exact monitor queries)
- `sample/impl/INSTRUMENTATION.md` — `make tf-apply-dd` section

**Next module**: [Module 8 — AWS/EKS Deployment](Module-8-AWS-EKS-Deployment.md) — if running this
lab on AWS rather than a local cluster.
