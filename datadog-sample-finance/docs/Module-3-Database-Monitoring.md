# Module 3 — Database Monitoring (`make dbm`)

## Overview

`make dbm` turns on Database Monitoring for `postgres-ledger`, the PostgreSQL database backing
every payment write and the nightly reconciliation job. DBM is agent-side — no application code
changes — but it needs a dedicated, read-only database role before it can collect anything.

**Learning Objectives**
- Understand what DBM collects and why it needs its own database role
- Apply `make dbm` and confirm query metrics and explain plans appear
- Understand the APM ↔ DBM correlation link and why it depends on Module 2's UST already being in place

**Recommended Duration:** 30–45 minutes

**Prerequisites:** Module 2 complete (UST applied) — DBM's correlation with APM traces depends on
`db.instance` tags that only mean something once services are tagged.

## Section 1 — What `make dbm` Does

Two narrated steps, tracked by one sentinel (`.dbm-applied`):

- **(a) Agent-side config** — applies `dbm-agent.patch`, uncommenting the `postgres.d` check
  config and `DD_DBM_POSTGRES_PASSWORD` wiring in `datadog-agent.yaml`. A ConfigMap/env var alone
  does nothing unless mounted this way.
- **(b) PostgreSQL role** — creates/refreshes a read-only `datadog` role, grants
  `pg_stat_statements`, and the `datadog.explain_statement` function (needed for EXPLAIN plans) by
  running `scripts/dbm-setup.sql` inside the `postgres-ledger` pod.

Password source order for step (b): the `datadog-secret`'s `dbm-password` key, else
`DATADOG_DBM_PASSWORD` in `.env`. If neither is set, step (b) is skipped and DBM stays off at the
database level even though the Agent-side patch applied cleanly — check both halves when
troubleshooting.

> **Not auto-run.** `make deploy-k8s-dd` no longer runs this for you — `make dbm` must be run
> explicitly, after `make create-dd-secret` / `make deploy-k8s-dd`.

## Section 2 — Why It Matters

DBM authenticates the Agent to Postgres via this dedicated read-only role to collect query
metrics, live query samples, and EXPLAIN plans — all without touching `account-service` or
`batch-processor` code. The read-only constraint (`pg_monitor` role only, never superuser) matters
for a financial ledger database specifically: the monitoring path should never be able to write.

## Section 3 — Workflow

```bash
make dbm
# Redeploy the Agent to pick up the new mount:
#   Local: kubectl apply -k deploy/kubernetes/datadog/agent && kubectl rollout restart daemonset/datadog-agent -n datadog
#   EKS:   kubectl apply -k deploy/kubernetes/overlays/eks-datadog && kubectl rollout restart daemonset/datadog-agent -n datadog
```

**Reverse it:**
```bash
make undbm     # runs scripts/dbm-teardown.sql (revokes/drops the 'datadog' role), then reverses the Agent-side patch
```

`pg_stat_statements` (the extension itself) is left installed by `make undbm` — it's server-wide,
not scoped to the role.

## Validate

Databases → Query Metrics — queries from `postgres-ledger` appear. Open a sample → **Explain
Plan** (only available thanks to step (b)'s `datadog.explain_statement` function).

```bash
kubectl exec -n datadog daemonset/datadog-agent -c agent -- agent status
# 'no valid instances'       → check the YAML under deploy/kubernetes/datadog/checks/
# 'pg_stat_statements error' → step (b) hasn't run or failed
# 'authentication failed'    → verify dbm-password in the datadog-secret
```

## Practical Exercise

**Goal:** Enable DBM and prove the APM ↔ DBM correlation works on a real Meridian Financial query.

**Time:** 20–30 minutes

**Steps:**
1. `make dbm`, then redeploy the Agent per the workflow above.
2. Confirm `postgres-ledger` queries appear under Databases → Query Metrics.
3. Generate payment traffic (the in-cluster `traffic-generator` already does this).
4. Open a `POST /v1/payments` trace in APM, find the `ledger.velocity_check` db span, and click
   **View in DBM** — confirm it lands on an explain plan for that exact query.
5. Reverse it: `make undbm` and confirm Query Metrics stop updating.

**Expected outcome:** A working, demonstrated APM-span → DBM-explain-plan jump for at least one
real query, and a clean reversal.

## Resources & Next Steps

- Database Monitoring: https://docs.datadoghq.com/database_monitoring/
- DBM — PostgreSQL self-hosted setup: https://docs.datadoghq.com/database_monitoring/setup_postgres/selfhosted/
- DBM + APM correlation: https://docs.datadoghq.com/database_monitoring/connect_dbm_and_apm/
- `sample/impl/INSTRUMENTATION.md` — `make dbm` section, full validate/troubleshoot detail
- Preview ahead: Module 7's diagnosis lab Scenario 1 drops the index this same query relies on —
  worth remembering this module's `ledger.velocity_check` query name for later.

**Next module**: [Module 4 — APM, Data Streams & Data Jobs Monitoring (`make instrument`)](Module-4-APM-DSM-DJM.md)
