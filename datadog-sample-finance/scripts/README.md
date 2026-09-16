# scripts/ — Traffic Generator

This directory contains the traffic generator that drives realistic, mixed load against the
Finance Sample App running on **Kubernetes** (local k3s or EKS). The project has no Docker
Compose workflow — everything runs as Kubernetes Deployments in the `finance` namespace.

Traffic generation is **automatic by default**: an in-cluster `traffic-generator` Deployment
(`deploy/kubernetes/base/services/traffic-generator.yaml`) runs this same script continuously,
talking to services over ClusterIP DNS — no laptop, port-forwards, or manual steps required.
Running the script directly from your laptop is an optional override, useful for a quick
one-off smoke test.

---

## `generate-traffic.py`

A single-file Python script (standard library only — no `pip install` required) that:

1. Obtains JWT Bearer tokens for all four Keycloak finance-realm users
2. Seeds a set of test accounts directly on `account-service`
3. Runs a weighted random loop of Finance-domain scenarios against `gateway-api`,
   `account-service`, `transaction-service`, and `batch-processor`
4. Tokens are automatically refreshed before they expire

---

## Primary usage: the in-cluster `traffic-generator` Deployment (default)

`make deploy-k8s` applies `deploy/kubernetes/base/services/traffic-generator.yaml`
alongside the rest of the app. That Deployment runs this exact script in a loop,
reaching services via their ClusterIP DNS names (`gateway-api:8080`,
`account-service:8081`, `transaction-service:8082`, `batch-processor:8083`,
`keycloak:8080`). It starts automatically and keeps running — no laptop involvement.

```bash
# Watch live output
kubectl logs -n finance deploy/traffic-generator -f

# Pause traffic (scale to 0 replicas)
kubectl scale deployment traffic-generator --replicas=0 -n finance

# Resume traffic
kubectl scale deployment traffic-generator --replicas=1 -n finance

# Tune the rate (requests per second) without restarting from scratch
kubectl set env deployment/traffic-generator TRAFFIC_RATE=5 -n finance
```

The default rate is `TRAFFIC_RATE=2` (2 req/s), set in the Deployment spec — enough to
produce meaningful APM data without overwhelming a demo cluster. Raise it for load
testing, lower it for quiet demos.

The generator pod is deliberately **not** instrumented with Datadog (no
`admission.datadoghq.com/enabled` annotation) — it's tooling, not a Finance service, so
its own traces would just add noise to APM.

---

## Optional: running the script manually from your laptop

Useful for a one-off smoke test or when iterating on the script itself. The script
reads its target URLs from environment variables, defaulting to the in-cluster
ClusterIP DNS names — override them to point at `localhost` via `kubectl port-forward`:

```bash
# Start port-forwards (one per service you want to exercise)
kubectl port-forward svc/gateway-api 8080:8080 -n finance &
kubectl port-forward svc/account-service 8081:8081 -n finance &
kubectl port-forward svc/transaction-service 8082:8082 -n finance &
kubectl port-forward svc/batch-processor 8083:8083 -n finance &
kubectl port-forward svc/keycloak 8089:8080 -n finance &

# Run from the project root (impl/), overriding the service URLs
GATEWAY_URL=http://localhost:8080 \
ACCOUNTS_URL=http://localhost:8081 \
TXNS_URL=http://localhost:8082 \
BATCH_URL=http://localhost:8083 \
KEYCLOAK_URL=http://localhost:8089 \
python3 scripts/generate-traffic.py
```

### Prerequisites

| Requirement | Detail |
|---|---|
| Python | 3.8+ (standard library only) |
| Running stack | `make deploy-k8s` from the project root |
| Port-forwards | Only needed for the manual/laptop path — see above |

### Flags

```bash
# One pass through every scenario type — good for a quick smoke-test
python3 scripts/generate-traffic.py --once

# Continuous traffic at the default rate (1 req/s) — Ctrl-C to stop
python3 scripts/generate-traffic.py

# Higher rate
python3 scripts/generate-traffic.py --rate 5

# Run for a fixed window (e.g. 5 minutes to populate an APM dashboard)
python3 scripts/generate-traffic.py --rate 3 --duration 300
```

| Flag | Default | Description |
|---|---|---|
| `--rate N` | `1.0` | Target requests per second |
| `--duration N` | `0` (forever) | Stop after N seconds |
| `--once` | — | Run one pass through each scenario, then exit |

### Environment variables

| Variable | Default (in-cluster) | Purpose |
|---|---|---|
| `GATEWAY_URL` | `http://gateway-api:8080` | Public gateway (JWT-protected) |
| `ACCOUNTS_URL` | `http://account-service:8081` | Direct account-service calls |
| `TXNS_URL` | `http://transaction-service:8082` | Direct transaction-service calls |
| `BATCH_URL` | `http://batch-processor:8083` | Triggers the reconciliation batch job |
| `KEYCLOAK_URL` | `http://keycloak:8080` | Token endpoint |
| `KEYCLOAK_CLIENT_SECRET` | `REPLACE_WITH_SECRET` | Must match the `finance-gateway` client secret (`keycloak-client-secret` key of the `app-secrets` Secret) or token requests 401 |

---

## Keycloak users

All four users in the `finance` realm are used, each representing a different
role encountered in a real banking platform:

| Username | Role | What they can do |
|---|---|---|
| `alice.analyst` | `finance-analyst` | Read-only: balance checks |
| `bob.trader` | `finance-trader` | Initiate payments and transfers |
| `carol.admin` | `finance-admin` | Full access |
| `dave.auditor` | `finance-auditor` | Read-only: compliance view |

Passwords: `Finance@2025!` (local dev only — see `identity-provider/README.md`).

---

## Traffic scenario breakdown

| Scenario | Weight | Services hit | HTTP method |
|---|---|---|---|
| Balance check (via gateway, JWT) | 30 | gateway-api → account-service | `GET /v1/accounts/{id}/balance` |
| Payment initiation (via gateway, JWT) | 25 | gateway-api → transaction-service → ActiveMQ | `POST /v1/payments` |
| Account lookup (direct) | 20 | account-service → PostgreSQL | `GET /v1/accounts/{id}` + balance |
| Health checks (all services) | 10 | gateway-api, account-service, transaction-service | `GET /health` |
| 404 — unknown resource | 7 | account-service, transaction-service | `GET` missing IDs |
| 401 — no token | 5 | gateway-api | `GET` + `POST` without `Authorization` header |
| 422 — bad payload | 3 | gateway-api | `POST /v1/payments` with invalid body |
| Batch job trigger (reconciliation) | 2 | batch-processor | `POST /jobs/reconciliation` |

Weights are relative (they don't need to sum to 100) — the script picks a scenario each
loop iteration via weighted random choice out of the total (currently 102). The batch
job scenario is intentionally low-weight since each run reads/writes the ledger DB; it
exists to produce a steady stream of `batch.job` / `batch.step` spans for Data Jobs
Monitoring without waiting for the nightly cron.

### Full request flow for a payment scenario

```
generate-traffic.py
  └─ POST /v1/payments  →  gateway-api :8080          (JWT validated)
       └─ POST /internal/transactions  →  transaction-service :8082
            ├─ ledger.commit()                          (in-memory stub)
            └─ JMS publish → fraud.score.queue
                  └─ fraud-detection                   (async consumer)
                        └─ JMS publish → alert.queue
                               └─ notification-service (async consumer)
```

Each payment triggers the full async chain through ActiveMQ Artemis, exercising
Data Streams Monitoring (DSM) paths once that layer is enabled.

---

## What to watch while the script runs

### Console UIs

| Console | URL | What to look for |
|---|---|---|
| ActiveMQ management | `kubectl port-forward svc/activemq-artemis 8161:8161 -n finance` → http://localhost:8161/console | `fraud.score.queue` depth, consumer count |
| Keycloak admin | `kubectl port-forward svc/keycloak 8089:8080 -n finance` → http://localhost:8089 | Active sessions per realm user |

Default ActiveMQ web console credentials: `admin` / value of the `artemis-password` key
in the `app-secrets` Secret (default dev value `artemis_dev_password`, see
`deploy/kubernetes/base/02-secrets.yaml`).

Default Keycloak admin credentials: `admin` / value of the `keycloak-admin-password` key
in the same `app-secrets` Secret (default dev value `Finance@Admin2025!`). There is no
`KEYCLOAK_ADMIN_PASSWORD` in `.env` — Keycloak's admin password lives only in the K8s
Secret.

### Logs

```bash
# In-cluster traffic generator
kubectl logs -n finance deploy/traffic-generator -f

# Individual services
kubectl logs -n finance deploy/gateway-api -f
kubectl logs -n finance deploy/transaction-service -f
kubectl logs -n finance deploy/fraud-detection -f
```

### PostgreSQL

`.env.example` does not define `POSTGRES_USER` — the ledger DB credentials live in the
`app-secrets` K8s Secret. Port-forward and read the credentials from the Secret:

```bash
kubectl port-forward svc/postgres-ledger 5432:5432 -n finance

# In another terminal
POSTGRES_USER=$(kubectl get secret app-secrets -n finance -o jsonpath='{.data.postgres-user}' | base64 -d)
psql -h localhost -U "$POSTGRES_USER" -d ledger
# password: value of the postgres-password key (default dev value finance_dev_password)

# See accounts seeded by the script
SELECT id, owner_id, tier, currency, balance FROM accounts;
```

---

## Relationship to the Datadog Learning Progression

The traffic generator is useful at **every step** of the Learning Progression in
`INSTRUMENTATION.md`:

| Step | What the generator proves |
|---|---|
| Step 1 — Structured JSON logs | Log lines have the Finance JSON schema |
| Step 2 — Unified Service Tagging | `env`, `service`, `version` tags appear on all telemetry |
| Step 3 — APM | Traces appear in APM > Services; payment flow visible as a distributed trace |
| Step 4 — Log–trace correlation | `dd.trace_id` appears in log records; "View in APM" button works |
| Step 5 — Custom spans | `payment.authorize`, `account.balance_check` spans appear in flame graphs |
| Step 6 — Custom metrics | `finance.payment.initiated`, `finance.payment.processing_time` in dashboards |
| Step 9 — Database Monitoring | Account and transaction queries appear in Databases > Query Samples |
| Step 10 — ActiveMQ JMX metrics | `fraud.score.queue` depth and consumer count visible in the ActiveMQ integration |
| Step 12 — Synthetic Monitoring | Use alongside Synthetic tests to compare real vs. scripted traffic |

The in-cluster `traffic-generator` Deployment already keeps this data fresh continuously.
Use the manual/laptop invocation (`python3 scripts/generate-traffic.py --rate 3 --duration 300`)
only if you need a targeted burst before opening a specific Datadog product page.
