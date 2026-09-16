# Module 0 — Project & Customer Scoping

## Overview

Before any `make` target runs, a Datadog deployment needs a scope. This module walks the
partner-scoping methodology using **Meridian Financial** — the fictional customer this entire
hands-on lab (`sample/impl`) models: a mid-market financial services company that processes
payments, manages customer accounts, runs nightly reconciliation, and screens transactions for
fraud asynchronously.

This module is deliberately *not* organized around a `make` step — it happens before any command
is run, while you're still deciding what to build and why.

**Learning Objectives**
- Read a customer's architecture for monitoring blind spots before proposing anything
- Map each architecture component to the Datadog capability that closes its gap
- Translate real customer pain points into business impact and priority
- Produce a phased, justified proposal — not a feature checklist

**Recommended Duration:** 45–60 minutes

**Prerequisites:** none — this module has no dependency on the app being deployed.

## Step 1 — Read the Architecture

Meridian Financial's platform (see `sample/impl/README.md` for the full diagram):

| Service | Language | Role |
|---|---|---|
| `gateway-api` | Python / FastAPI | Public REST API, OIDC auth middleware |
| `account-service` | Java / Spring Boot | Account CRUD, balance enquiry, JMS producer |
| `transaction-service` | Node.js / Express | Payment initiation, ledger write, JMS producer |
| `fraud-detection` | Python | Async fraud scoring — JMS consumer |
| `notification-service` | Go | Async email/SMS stubs — JMS consumer |
| `batch-processor` | Java / Spring Batch | Nightly reconciliation and settlement |

Supporting infrastructure: PostgreSQL (ledger database), Redis (session cache), ActiveMQ Artemis
(JMS broker), Keycloak (identity).

Before proposing anything, walk the architecture and ask:

- **Where's the critical path?** For Meridian, it's `gateway-api → transaction-service →
  PostgreSQL` (every payment) and `transaction-service → ActiveMQ → fraud-detection` (every fraud
  score). A slowdown or backlog anywhere on these two paths is customer-facing.
- **What's beyond the app layer?** PostgreSQL query performance, ActiveMQ queue depth, and the
  nightly batch job all sit outside any one service's own code — none of them show up in a plain
  APM trace unless something is specifically watching them.
- **Where are the monitoring gaps today?** A job that reports `COMPLETED` but silently processed
  fewer records than it should; a queue that backs up because the *producer* misbehaved, not the
  consumer; a query that's fine until the table grows. None of these throw exceptions.
- **Who owns what?** Without named ownership, a monitor that fires at 3am has nobody to act on it.

## Step 2 — Build the Initial Proposal

Map each architecture component to the Datadog capability that addresses its blind spot:

| Architecture component | Blind spot | Datadog capability |
|---|---|---|
| `gateway-api`, `account-service`, `transaction-service` | No distributed trace across services | APM, Unified Service Tagging |
| PostgreSQL (`postgres-ledger`) | Query performance invisible without DBA access | Database Monitoring |
| ActiveMQ Artemis (`fraud.score.queue`, `alert.queue`) | Can't tell producer overload from consumer lag | Data Streams Monitoring |
| `batch-processor` (Spring Batch) | A job can report success while doing less work than expected | Data Jobs Monitoring |
| Finance dashboard (frontend) | No visibility into real user sessions or errors | Real User Monitoring, Session Replay |
| All 6 services | Dependency CVEs, injection attacks, container drift | ASM, CWS, CSPM |
| Everything above | No alerting, no SLOs, no single pane of glass | Dashboards, Monitors, SLOs |

## Step 3 — Listen to Customer Requirements

A proposal built only from the architecture is technically correct but not prioritized. Real
customer pain points (worked examples, adapt to your actual engagement):

| Customer says | Business impact | Datadog capability | Priority |
|---|---|---|---|
| "Customers are complaining payments are slow" | Revenue / churn risk, customer-facing | APM + DBM (root-cause the slow query) | 1 — revenue |
| "Compliance needs an audit trail of every approval" | Regulatory risk | Log Management + RBAC | 2 — compliance/risk |
| "Our fraud team says alerts arrive too late" | Fraud exposure window | Data Streams Monitoring | 1 — revenue/risk |
| "We found out about a bad reconciliation run three days later" | Financial discrepancy risk | Data Jobs Monitoring | 2 — compliance/risk |
| "We want fewer manual dashboard checks" | Operational efficiency | Dashboards + Monitors + SLOs | 3 — efficiency |

## Step 4 — Adjust and Prioritize

Phase the proposal — don't propose all seven capabilities on day one:

1. **Phase 1 — Revenue impact first:** APM + UST + DBM. Gets a team looking at the payment path
   with real trace data within days.
2. **Phase 2 — Compliance / risk:** Data Streams Monitoring (fraud queue), Data Jobs Monitoring
   (reconciliation), Log Management with trace correlation.
3. **Phase 3 — Operational efficiency:** Dashboards, Monitors, SLOs, RUM, Security (ASM/CWS/CSPM).

State explicit success criteria per phase (e.g., "Phase 1 done when a slow payment can be traced
from APM span to Postgres explain plan without touching a terminal") — not just "APM is on."

## Practical Exercise

**Goal:** Produce a phased proposal for Meridian Financial you could hand to a customer
stakeholder before Module 1 starts.

**Time:** 20–30 minutes

**Steps:**
1. Fill in the architecture-to-capability mapping table above with one sentence per row justifying
   the mapping for Meridian Financial specifically (not generically).
2. Pick two customer pain points from Step 3 (or invent two grounded in the architecture) and
   assign each a priority phase.
3. Write one success criterion per phase.

**Expected outcome:** A one-page phased proposal, grounded in Meridian Financial's actual
architecture (not a generic template), that maps directly onto Modules 1–8.

## Resources & Next Steps

- Getting Started with Datadog: https://docs.datadoghq.com/getting_started/
- Getting Started with Tagging (the taxonomy this scoping exercise feeds into): https://docs.datadoghq.com/getting_started/tagging/
- Reference Implementation Project Plan (WBS template this scoping exercise maps to): see the vault-level Partner-Training Index for the current link

This scoping exercise maps onto the rest of the curriculum as follows:

| Phase | Modules |
|---|---|
| Phase 1 — Revenue impact | Module 1 (Foundation & Deploy), Module 2 (Tagging), Module 3 (DBM), Module 4 (APM/DSM/DJM) |
| Phase 2 — Compliance / risk | Module 4 (DSM/DJM), Module 6 (Security) |
| Phase 3 — Operational efficiency | Module 5 (RUM), Module 7 (Dashboards/Monitors + diagnosis lab) |
| Infrastructure choice | Module 8 (AWS/EKS) if not running locally |

**Next module**: [Module 1 — Foundation & Deploy](Module-1-Foundation-and-Deploy.md)
