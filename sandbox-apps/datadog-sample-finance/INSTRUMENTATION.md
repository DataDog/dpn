# Meridian Financial — Instrumentation Guide

This guide covers **what each observability signal enables and how to turn it on**, one pipeline stage at a time. Rebuilding images and redeploying to Kubernetes — for both local and AWS/EKS — are covered once, right below, in [Rebuilding & redeploying](#rebuilding--redeploying). Each stage section below just tells you which category applies.

---

## Quick Start

Everything below is opt-in and commented out by default. The full pipeline, in order:

```bash
make tags          # Unified Service Tagging + log injection
make dbm           # Database Monitoring (PostgreSQL)
make instrument    # APM custom spans + Single Step Instrumentation + Continuous Profiler + DSM/DJM
make dem           # Digital Experience Monitoring (Browser RUM)
make security      # ASM + CWS + CSPM
make tf-apply-dd   # Dashboards, monitors, SLOs, synthetics
```

Every stage has a reverse target (`make untag`, `make undbm`, `make uninstrument`, `make undem`, `make unsecurity`, `make tf-destroy-dd`) and is idempotent — running it twice in a row without reversing first is a safe no-op (tracked via a `.{stage}-applied` sentinel file).

**Nothing here is automatic.** A fresh `make deploy-k8s` + `make deploy-k8s-dd` does **not** enable Single Step Instrumentation, DBM, ASM/CWS/CSPM, UST, log injection, or RUM — all six manifests and the Agent config ship with these commented out. Each section below is the single source of truth for its stage's workflow.

---

## Rebuilding & redeploying

Every stage below falls into one of three categories. Each stage section names its category instead of repeating the commands.

**Category A — source code changed → full rebuild + redeploy**
- Local: `make build`, then re-import the image into your cluster if it doesn't pick up the new build automatically, then `make deploy-k8s`.

> Re-importing locally depends on which local Kubernetes you're running — a quick reference (images are tagged `finance-sample-app-<svc>:latest`):
>
> - **Docker Desktop / Rancher Desktop** — no re-import needed, the daemon is shared with the cluster.
> - **kind** — `kind load docker-image finance-sample-app-<svc>:latest`
> - **k3d** — `k3d image import finance-sample-app-<svc>:latest`
> - **minikube** — `minikube image load finance-sample-app-<svc>:latest`
> - **Colima** (containerd) — `docker save finance-sample-app-<svc>:latest | colima ssh -- sudo ctr -n k8s.io image import -`

- AWS/EKS: `make build-ecr && make deploy-k8s-eks`.

**Category B — Kubernetes manifest changed only (env var / label / annotation toggle, no source touched) → redeploy only, no rebuild**
- Local: `make deploy-k8s` — AWS/EKS: `make deploy-k8s-eks`.
- `kubectl apply` updates the Deployment spec directly and triggers its own rollout — no separate `kubectl rollout restart` needed.

**Category C — Datadog Agent config changed → Agent only, app untouched**
- Local: `kubectl apply -k deploy/kubernetes/datadog/agent && kubectl rollout restart daemonset/datadog-agent -n datadog`
- AWS/EKS: `kubectl apply -k deploy/kubernetes/overlays/eks-datadog && kubectl rollout restart daemonset/datadog-agent -n datadog`

| Stage | Category |
|---|---|
| `make tags` | A |
| `make dbm` | C |
| `make instrument` | A |
| `make dem` | special — its own ConfigMap flow, see below |
| `make security` | C (Agent side) + B (app side) |

---

## `make tags`

### What it does

Three narrated steps, applied via unified diff patches under `scripts/patches/tags/` (a separate directory from the top-level `scripts/patches/*.patch` used by `make instrument`, so the two lifecycles' globs never collide):

| Step | Target | Mechanism | What it enables |
|---|---|---|---|
| (a) UST | all 6 manifests | `scripts/patches/tags/ust-<service>.patch` | Uncomments `tags.datadoghq.com/env\|service\|version` pod labels + `DD_ENV`/`DD_SERVICE`/`DD_VERSION` env vars (`DD_AGENT_HOST` is untouched — always active, not a UST concern). `transaction-service`'s patch also has a second hunk for `src/index.js`, uncommenting the `base: { service, env, version }` object passed to the `pino` logger — the same UST fields, stamped onto every JSON log line directly by the app instead of relying on the Agent to infer them |
| (b) Log injection — Python | `gateway-api`, `fraud-detection` | `scripts/patches/tags/loginject-<service>.patch` | Uncomments the `ddtrace.contrib.logging.patch` import + `patch_logging()` call |
| (b) Log injection — Node | `transaction-service` | `scripts/patches/tags/loginject-transaction-service.patch` | Uncomments `logInjection: true` in the `dd-trace` init block |
| (b) Log injection — Java | `account-service`, `batch-processor` | `scripts/patches/tags/loginject-<service>.patch` | Uncomments the `DD_LOGS_INJECTION=true` env var (dd-trace-java's Logback/Log4j2 MDC hook needs only this flag) |
| (b) Log injection — Go | `notification-service` | `scripts/patches/tags/loginject-notification-service.patch` | Uncomments manual `dd.trace_id`/`dd.span_id` field injection into the `alert.send`/`alert.send.complete` `slog` calls — Go has no automatic MDC-style hook |
| (c) Log collection annotation | all 6 manifests | `scripts/patches/tags/logs-<service>.patch` | Uncomments the `ad.datadoghq.com/<service>.logs` pod annotation the Agent uses for log source/service autodiscovery |

> **Go, Node, and Python log injection all require `make instrument` first.** `notification-service`'s uncommented fields read `span.Context().TraceID()`/`SpanID()` off the `alert.send` span, which only exists once `make instrument` has uncommented it — applying `make tags` alone leaves it referencing an undefined `span` variable and it will fail to build. `transaction-service`'s `logInjection: true` line lives inside the `require('dd-trace').init({...})` block, and `gateway-api`/`fraud-detection`'s `from ddtrace.contrib.logging import patch as patch_logging` + `patch_logging()` lines live right after their own `from ddtrace import ...` imports — all three are gated behind `make instrument` (see [`make instrument`](#make-instrument) → APM custom spans). Applying `make tags` before `make instrument` leaves these specific hunks a silent no-op (they can't find their context) rather than a build failure; re-run `patch -p1 --forward -s < scripts/patches/tags/loginject-<service>.patch` after `make instrument` if you want them applied out of order.
>
> **Step (c)'s patches assume `make tags` runs before `make instrument`** (the order the Quick Start already documents). `scripts/patches/instrument-sso/sso-*.patch` (see [`make instrument`](#make-instrument) → Single Step Instrumentation gating) rewrites the same `annotations:` block and expects step (c) to have already run — reversing the two makes both a no-op instead of an error, so always apply/reverse in the documented order.

### Why it matters

`DD_ENV`/`DD_SERVICE`/`DD_VERSION` (+ `tags.datadoghq.com/*` pod labels) are what let Datadog group traces/logs/metrics by service and correlate deploys via Deployment Tracking. Log injection stitches JSON logs to APM traces so "View in APM" works from Log Management — without it, logs and traces exist independently. The log collection annotation tells the Agent which `source`/`service` to tag a pod's collected logs with, for correct pipeline parsing and faceting.

### Workflow

```bash
make tags               # apply UST + log injection + log collection annotation patches
```

Rebuild + redeploy — **Category A** (see [Rebuilding & redeploying](#rebuilding--redeploying)).

### Reverse it

```bash
make untag               # re-comments all UST + log-injection + log collection annotation patches
```

Rebuild + redeploy again — Category A.

### Validate

Any trace or log should carry `env:staging service:<name> version:latest`. Log Explorer → click any log from a finance service → **View Trace** button appears once `dd.trace_id` is present. Log Explorer → `kube_namespace:finance` should show correctly source-tagged logs (e.g. `source:nodejs` for `transaction-service`) once the annotation is uncommented and the pod redeployed.

---

## `make dbm`

### What it does

Two narrated steps, sentinel `.dbm-applied`:

- **(a) Agent-side config** — applies `scripts/patches/dbm/dbm-agent.patch`, uncommenting the `postgres.d` check config and the `DD_DBM_POSTGRES_PASSWORD` wiring in `datadog-agent.yaml`. A ConfigMap/env var alone does nothing unless mounted like this.
- **(b) PostgreSQL role** — creates/refreshes the read-only `datadog` role, grants `pg_stat_statements`, and the `datadog.explain_statement` function (for EXPLAIN plans) by running `scripts/dbm-setup.sql` inside the `postgres-ledger` pod.

Password source order for step (b): the `datadog-secret` `dbm-password` key, else `DATADOG_DBM_PASSWORD` in `.env`. If neither is set, step (b) is skipped and DBM stays off at the DB level even though the Agent-side patch is applied. **This is no longer auto-run by `make deploy-k8s-dd`** — run `make dbm` explicitly after `make create-dd-secret` / `make deploy-k8s-dd`.

### Why it matters

DBM needs the Agent to authenticate to Postgres via a dedicated read-only role to collect query metrics, live query samples, and EXPLAIN plans — without code changes to `account-service`/`batch-processor`.

### Workflow

```bash
make dbm
```

Redeploy the Agent to pick up the new mount — **Category C** (see [Rebuilding & redeploying](#rebuilding--redeploying)).

### Reverse it

```bash
make undbm     # runs scripts/dbm-teardown.sql (revokes/drops the 'datadog' role), then reverses the Agent-side patch
```

`pg_stat_statements` the extension is left installed by `make undbm` — it's server-wide, not scoped to the role.

### Validate

Databases → Query Metrics — queries from `postgres-ledger` appear; open a sample → **Explain Plan** (available thanks to the `datadog.explain_statement` function from step (b)).

```bash
kubectl exec -n datadog daemonset/datadog-agent -c agent -- agent status
# 'no valid instances'       → check YAML in deploy/kubernetes/datadog/checks/
# 'pg_stat_statements error' → make dbm step (b) hasn't run or failed
# 'authentication failed'    → verify dbm-password in the datadog-secret
```

---

## `make instrument`

Applies reversible unified-diff patches in four narrated steps under one sentinel (`.instrumentation-applied`), plus a Service Catalog reminder. Reversing (`make uninstrument`) runs the same four steps in the opposite order.

### 1. APM custom spans

`scripts/patches/*.patch` (top-level directory — not `scripts/patches/tags/`, `dbm/`, `security/`, or `instrument-sso/`):

| Target | Mechanism | What it enables |
|---|---|---|
| `gateway-api` | `scripts/patches/gateway-api.patch` | Uncomments `import ddtrace.profiling.auto`, `from ddtrace import patch_all, tracer`, and `patch_all()` in `main.py`, plus the `payment.authorize` / `account.balance_check` custom spans — all in the same patch. No pip dependency is added: see [Single Step Instrumentation](#2-single-step-instrumentation-gating) below, which is what actually makes `ddtrace` importable for this service |
| `fraud-detection` | `scripts/patches/fraud-detection.patch` | Uncomments `from ddtrace import patch_all`, `patch_all()`, and `import ddtrace.profiling.auto` in `main.py`, plus `from ddtrace import tracer` and the `fraud.score` custom span in `listener.py` — same no-pip-dependency note as `gateway-api` |
| `transaction-service` | `scripts/patches/transaction-service.patch` | Uncomments the dd-trace APM init (`require('dd-trace').init({...})`, including the nested log-injection block — see [`make tags`](#make-tags)) in `index.js`, adds `dd-trace` back to `package.json`, and uncomments the `payment.authorize` custom span in `payments.js` — all three live in the same patch |
| `notification-service` | `scripts/patches/notification-service.patch` | Uncomments `tracer.Start()` (APM), `profiler.Start()` (Continuous Profiler), and the `alert.send` custom span in `main.go` — all three live in the same patch/source banner |

> **Already active in source — no patch, always on:** `batch-processor` (`job.name` / `job.status` / `job.records_processed` span tags). `account-service` has no custom instrumentation (Java agent auto-instrumentation only).
>
> **`gateway-api`/`fraud-detection` intentionally have no `ddtrace` pip dependency, ever.** Unlike every other service here, `requirements.txt` never gains a real `ddtrace==` line — not even via this patch. These two services rely entirely on Single Step Instrumentation (step 2 below) to make `ddtrace` importable at pod startup. This means Step 1's uncommented code will raise `ModuleNotFoundError`/`NameError` unless step 2 has *also* run **and** the Datadog Operator/Admission Controller is actually installed in the cluster (`make deploy-k8s-dd`) **and** the pod has been redeployed so the webhook mutates it. `fraud-detection`'s separately-gated `ddtrace[data_streams]` extra (step 4, DSM) is the one exception that *is* pip-installed, since SSI's injected library doesn't include DSM's checkpoint API.
>
> **No DogStatsD anywhere.** Every `finance.*` custom metric is span-based (`datadog_spans_metric` in `deploy/terraform/datadog`, applied via `make tf-apply-dd`).

**Validate:** APM → Traces → filter by `resource_name:payment.authorize` or `operation_name:alert.send`.

### 2. Single Step Instrumentation gating

`scripts/patches/instrument-sso/sso-*.patch` — uncomments, on **all 6 service manifests**, the two things that opt a pod into tracer injection at startup:

**Pod label:**
```yaml
labels:
  admission.datadoghq.com/enabled: "true"
```

**Language annotation:**
```yaml
annotations:
  admission.datadoghq.com/python-lib.version: "v2"     # gateway-api, fraud-detection
  admission.datadoghq.com/js-lib.version: "v5"         # transaction-service
  admission.datadoghq.com/java-lib.version: "v1"       # account-service, batch-processor
  admission.datadoghq.com/go-lib.version: latest       # notification-service (no-op for Go — see note below)
```

Library versions are pinned to floating major tags (`v2`/`v1`/`v5`) rather than `latest` — reproducible across pod restarts, still receiving patches, always resolvable as init-image tags.

**Only after `make instrument` are these live** — before that, the label/annotation are commented out and the Datadog Operator's mutating admission webhook never touches these pods.

#### What gets injected

| Service | Library | Injection mechanism |
|---|---|---|
| `gateway-api` | `ddtrace` (Python) | `PYTHONPATH` + auto-instrumentation |
| `fraud-detection` | `ddtrace` (Python) | same |
| `transaction-service` | `dd-trace` (Node.js) | `NODE_OPTIONS=--require dd-trace/init` |
| `account-service` | `dd-java-agent` (Java) | `JAVA_TOOL_OPTIONS=-javaagent:...` |
| `batch-processor` | `dd-java-agent` (Java) | same |
| `notification-service` | `dd-trace-go` (Go) | **not single-step injected** — in-code `tracer.Start()`, see step 1 above |

The injected agent also sets `DD_TRACE_AGENT_URL`, `DD_INSTRUMENTATION_INSTALL_TYPE=k8s_lib_injection`, and `DD_APPSEC_ENABLED=true` (from the ASM feature flag, see `make security`) automatically.

> **What actually provides the tracer (important nuance):**
> - **Python** (`gateway-api`, `fraud-detection`) deliberately have **no** `ddtrace` pin in their own `requirements.txt` — unlike every other service here, this pip dependency is permanently absent, not just commented-out-until-`make instrument`. That means the SSI-injected library (via `PYTHONPATH`) is the *only* source of `ddtrace` for these two services, with nothing baked into the image to shadow it. `import ddtrace` reports whatever version the `python-lib.version` annotation resolves to; there is no rebuild-and-repin path for these two, by design — the whole point is to exercise SSI as the actual delivery mechanism instead of working around it.
> - **Go** (`notification-service`) is **not** single-step injected — the Admission Controller creates no init container for Go, so `go-lib.version` is a no-op. Go tracing comes entirely from the in-code `tracer.Start()` enabled in step 1 above.

#### Verify injection

```bash
# Init containers present?
kubectl get pod -n finance -l app=gateway-api \
  -o jsonpath='{.items[0].spec.initContainers[*].name}'
# Expected: datadog-lib-python-init datadog-init-apm-inject

# ddtrace version loaded?
kubectl exec -n finance deploy/gateway-api -- \
  python3 -c "import ddtrace; print(ddtrace.__version__)"

# Injection type env var?
kubectl exec -n finance deploy/gateway-api -- env | grep DD_INSTRUMENTATION
# Expected: DD_INSTRUMENTATION_INSTALL_TYPE=k8s_lib_injection
```

#### Admission Controller injection not working

```bash
# Required label on pod?
kubectl get pod -n finance -l app=gateway-api \
  -o jsonpath='{.items[0].metadata.labels.admission\.datadoghq\.com/enabled}'
# Expected: true

# Webhook registered?
kubectl get mutatingwebhookconfigurations datadog-webhook \
  -o jsonpath='{.webhooks[?(@.name=="datadog.webhook.lib.injection")].objectSelector}'
```

Common causes:
- **Label/annotation missing** — `make instrument` hasn't been run, or its patch failed (see [Makefile targets](#makefile-targets) → patch-failure recovery in [TROUBLESHOOTING.md](./TROUBLESHOOTING.md)).
- **Operator not watching the namespace** — check `watchNamespaces` in Helm values.
- **Webhook not reconciled** — `kubectl logs -n datadog deploy/datadog-cluster-agent | grep -i admission`. This webhook has `failurePolicy: Ignore`, so pods still start successfully with **no error at all** — the only symptom is instrumentation silently not happening.

### 3. Continuous Profiler

`scripts/patches/instrument-sso/profiler-*.patch` — uncomments `DD_PROFILING_ENABLED=true` on **5 of 6 services** (Python: `gateway-api`, `fraud-detection`; Node: `transaction-service`; Java: `account-service`, `batch-processor` via `-Ddd.profiling.enabled=true`). **Not `notification-service`** — its Go profiler (`profiler.Start()`) is already gated by step 1's patch, in the same source banner as the Go APM tracer.

**Validate:** APM → Profiles — flame graphs appear within ~1 minute. Correlates CPU flame graphs with slow payment traces or slow batch job steps.

### 4. Data Streams / Data Jobs Monitoring

`scripts/patches/instrument-sso/dsm-*.patch` + `djm-batch-processor.patch` — uncomments `DD_DATA_STREAMS_ENABLED=true` on the four JMS services (`account-service`, `transaction-service`, `fraud-detection`, `notification-service`) and `DD_DATA_JOBS_ENABLED=true` on `batch-processor`. `gateway-api` has neither block — it doesn't produce or consume JMS messages.

DSM gives producer→consumer latency and consumer-lag visibility across the payment → fraud → notification flow. `transaction-service` (Node.js) has an active manual producer checkpoint (`tracer.dataStreamsCheckpointer.setProduceCheckpoint`, in `producer.js`) and `fraud-detection` (Python) has an active manual consumer checkpoint (`set_consume_checkpoint`, in `listener.py`) — both already uncommented and working. DJM surfaces Spring Batch job runs under APM → Data Jobs — primarily built for Spark/Databricks workloads, so for a plain Spring Batch app the step 1 APM spans + `job.*` tags already cover most needs.

> **Known limitation — `account-service`'s JMS producer checkpoint cannot be made to work, on any dd-trace-java version.** `account-service/src/main/java/.../PaymentEventProducer.java` still ships with its DSM checkpoint block commented out (Step 10), and it should **stay** commented out — do not uncomment it. dd-trace-java's JMS auto-instrumentation only calls the DSM checkpoint for **IBM MQ** (`JMSMessageProducerInstrumentation`/`JMSMessageConsumerInstrumentation` explicitly gate on `"ibmmq".equals(tech)`); ActiveMQ Artemis (and any other JMS broker) is classified `"unknown"` and silently skipped, regardless of `DD_DATA_STREAMS_ENABLED`. There is also no public, documented way to do this manually for JMS: a hand-rolled `DataStreamsContextCarrier` that calls `message.setStringProperty()` will throw `JMSRuntimeException: AMQ139012 ... not a valid java identifier` — dd-trace-java's own pathway header (`dd-pathway-ctx-base64`) contains a hyphen, which the JMS 2.0 spec forbids in property names, and the internal hyphen-escaping trick that fixes this for trace-context propagation isn't exposed for DSM checkpoints. `notification-service`'s consumer side (`alert.queue`) has no checkpoint code at all either, for the same underlying reason. **Net effect: the DSM pathway map for this app will only ever show the `transaction-service → fraud.score.queue → fraud-detection` hop — not the `account-service` or `notification-service` legs.** The only way to get full DSM coverage here would be swapping Artemis for a broker on dd-trace-java's supported list (Kafka, RabbitMQ, SQS, Kinesis, SNS, Google Pub/Sub, IBM MQ) — a deliberate, separate architecture decision, not a quick fix, and one that would trade away Artemis's JMS-realism teaching value (mirroring IBM MQ/TIBCO EMS patterns common in banking/insurance). Docs: https://docs.datadoghq.com/data_streams/java/ (supported technologies list).

> **`fraud-detection` needs a rebuild, not just a redeploy.** Its DSM support is a baked pip dependency (`ddtrace[data_streams]` in `requirements.txt`, patched by `dsm-fraud-detection-requirements.patch`), unlike the other four services' plain env-var toggle. After `make instrument`, `fraud-detection` specifically needs `make build` (or `make build-ecr`) + image reload before DSM data appears — the env var alone isn't enough.

**Validate:** Data Streams → pathway map shows the `transaction-service → fraud.score.queue → fraud-detection` hop (docs: https://docs.datadoghq.com/data_streams/) — the `account-service`/`notification-service` legs will not appear, per the limitation above. APM → Data Jobs after a reconciliation run (docs: https://docs.datadoghq.com/data_jobs/).

### Service Catalog reminder

`make instrument` also prints a reminder that `service.datadog.yaml` already ships for all 6 services — there's no patch step for it, since these are static, git-committed metadata files with no on/off switch. See [Service Catalog: `service.datadog.yaml`](#service-catalog-servicedatadogyaml) below for the schema and how Datadog picks them up.

### Workflow

```bash
make instrument          # applies all 4 steps
```

Rebuild + redeploy — **Category A** (see [Rebuilding & redeploying](#rebuilding--redeploying)).

### Reverse it

```bash
make uninstrument       # reverses in opposite order: DSM/DJM → profiler → SSI gating → APM spans
```

Rebuild + redeploy again — Category A.

### Regenerating patches

If you modify any instrumented source file, regenerate the affected patch:

```bash
make uninstrument                        # must be in uninstrumented state first
python3 scripts/generate-patches.py     # regenerates service patches (gateway-api, fraud-detection, etc.)
for p in scripts/patches/*.patch; do
  patch --dry-run -p1 -s --input "$p" && echo "OK: $p" || echo "FAIL: $p"
done
```

**`scripts/patches/tags/*.patch` and `scripts/patches/instrument-sso/*.patch` (`sso-`, `profiler-`, `dsm-`, `djm-`) are hand-authored, not regenerated by this script.** `generate-patches.py`'s uncomment engine only understands Python/JS/Go/Java source syntax — it has no YAML support (and `dsm-fraud-detection-requirements.patch` targets a `requirements.txt`, not source). If you modify one of these patches' underlying file, edit the corresponding unified diff by hand and re-validate with the same `patch --dry-run` loop.

---

## `make dem`

`make dem` turns on Digital Experience Monitoring (DEM) — Browser RUM + Session Replay — for the `frontend-stub/index.html` dashboard. Unlike `make instrument`/`make tags`/`make security`, it does not apply a patch: it creates the RUM application via a **direct Datadog API call** (`POST /api/v2/rum/applications` — not Terraform, not `terraform-provider-datadog`) and injects the resulting credentials with `sed`.

### What it does

1. Resolves `DD_API_KEY`/`DD_APP_KEY` via the shared `resolve_dd_keys` canned recipe — the same `.env` (local) / AWS Secrets Manager (EKS) resolution used by `make create-dd-secret` and `make tf-apply-dd`. No separate credential setup.
2. Checks for an existing RUM application named `finance-frontend` (`GET /api/v2/rum/applications`, filtered client-side by name — the list endpoint has no server-side name filter) to avoid creating a duplicate on repeated runs.
3. Creates one if none exists (`POST /api/v2/rum/applications`), or reuses the existing one's `id`/`client_token` (`GET /api/v2/rum/applications/{id}` — the list endpoint doesn't return `client_token`, only the single-resource GET does).
4. Caches `id`/`client_token` in the gitignored `.dem-state.json` so re-runs and `make undem` don't need to re-query the API.
5. Uncomments the RUM `<script>` block in `frontend-stub/index.html` (`scripts/patches/dem/dem-frontend.patch`) — it ships fully commented out inside an HTML comment, like every other Datadog block in this repo, so the page has zero Datadog code at rest.
6. Injects the credentials into the now-active `DD_RUM.init()` block via `sed`.

Idempotent: tracked via `.dem-applied`. A second run without `make undem` first is a no-op. `make undem` reverses in the opposite order: restores the `REPLACE_WITH_*` placeholders first, then re-comments the `<script>` block.

### Why it matters

RUM captures real browser sessions for the finance dashboard — page loads, clicks, errors — and Session Replay lets you watch exactly what a user saw. This is the frontend counterpart to `make instrument`/APM, which only covers backend spans. Independent of `make instrument`, `make tags`, and `make tf-apply-dd` — Terraform no longer creates any RUM resource at all.

### API schema

```
POST https://api.<site>/api/v2/rum/applications
Headers: DD-API-KEY, DD-APPLICATION-KEY, Content-Type: application/json
Body:
{
  "data": {
    "type": "rum_application_create",
    "attributes": { "name": "finance-frontend", "type": "browser" }
  }
}
Response (data.id is the applicationId; data.attributes.client_token is the clientToken):
{
  "data": {
    "id": "<uuid>",
    "type": "rum_application",
    "attributes": { "application_id": "<uuid>", "client_token": "pub...", "name": "finance-frontend", "type": "browser", "api_key_id": <int>, ... }
  }
}
```

`<site>` comes from `DD_SITE` in `.env` (default `datadoghq.com`).

### What gets enabled

| Feature | Config |
|---|---|
| Page view tracking | Automatic — all navigation events |
| User interactions | `trackUserInteractions: true` — clicks, form submits |
| Session Replay | `sessionReplaySampleRate: 100` — full replay recorded |
| PII masking | `defaultPrivacyLevel: 'mask-user-input'` — form values never recorded |
| Service | `finance-frontend` — appears in RUM > Applications |

#### Finance-specific RUM actions (already instrumented in the dashboard)

The dashboard JS calls `appLog()`, wired to emit structured console events. After enabling RUM, replace `appLog()` calls with `DD_RUM.addAction()` to surface Finance-domain actions:

| Action | Trigger | Tags to add |
|---|---|---|
| `payment.initiated` | `POST /v1/payments` success | `amount_bucket`, `currency` |
| `balance.checked` | `GET /v1/accounts/{id}/balance` | `account_tier` |
| `login.success` | Keycloak token issued | `role` |
| `payment.validated` | Compliance role approves/rejects | `decision` |

**PII cardinality warning** — never pass raw `account_id`, `payment_id`, or exact amounts as RUM action attributes:
```javascript
amount_bucket: amount < 100 ? '<100' : amount < 1000 ? '100-1000' : '>1000'
```

### Workflow

```bash
make dem                # create/find the RUM app, inject credentials into frontend-stub/index.html
```

**Frontend RUM is special:** the dashboard HTML is served from the `frontend-dashboard` ConfigMap, *not* the container image, so a plain `rollout restart` alone replays the old HTML:

```bash
kubectl create configmap frontend-dashboard \
  --from-file=index.html=frontend-stub/index.html \
  -n finance --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment/frontend -n finance
```

### Reverse it

```bash
make undem              # deletes the RUM application via the API, restores the frontend placeholders
```

If `DD_API_KEY`/`DD_APP_KEY` can't be resolved, `make undem` fails with a clear error and leaves `.dem-applied`/`.dem-state.json`/the frontend untouched — retry once credentials are available.

### Validate

RUM → Applications → `finance-frontend` → Sessions → click any session → Session Replay available.

Docs: https://docs.datadoghq.com/real_user_monitoring/browser/

---

## `make security`

### What it does

Two narrated steps, one sentinel (`.security-applied`):

- **(a) Agent-side** — `scripts/patches/security/agent-security.patch` uncomments the `asm`/`cws`/`cspm` feature blocks in `datadog-agent.yaml`.
- **(b) App-side** — `scripts/patches/security/appsec-<service>.patch` (all 6 services) uncomments each service's `DD_APPSEC_ENABLED` env entry.

#### Agent configuration (uncommented by step (a))

```yaml
features:
  asm:
    threats:
      enabled: true
    sca:
      enabled: true
  cws:
    enabled: true
    syscallMonitorEnabled: true
  cspm:
    enabled: true
    hostBenchmarks:
      enabled: true
```

#### What is enabled

| Product | Layer | Detects |
|---|---|---|
| **ASM Threats** | APM tracer (app-side) | SQLi, XSS, SSRF, credential stuffing, business-logic attacks |
| **ASM SCA** | Agent-side | Known CVEs in Python / Java / Node.js / Go dependencies |
| **CWS** | Agent eBPF (kernel) | Shell spawned in container, file writes, privilege escalation, syscall anomalies |
| **CSPM** | Agent + cloud APIs | Privileged pods, exposed secrets, insecure RBAC, CIS / PCI-DSS findings |

### Why it matters

These agent features turn on the threat-intake pipeline, eBPF runtime monitoring, and CIS benchmark checks; the tracer needs `DD_APPSEC_ENABLED=true` to actually instrument requests for SQLi/XSS/SSRF/business-logic threats.

### Workflow

```bash
make security
```

Redeploy to activate — two categories, both from [Rebuilding & redeploying](#rebuilding--redeploying):
- **Agent** (`asm`/`cws`/`cspm` feature blocks) — **Category C**.
- **Apps** (`DD_APPSEC_ENABLED` env var only, no source touched) — **Category B**: just `make deploy-k8s` / `make deploy-k8s-eks`, no rebuild needed.

### Reverse it

```bash
make unsecurity          # restores every file to its original commented-out state
```

### Validate

```bash
# ASM active on gateway-api?
kubectl exec -n finance deploy/gateway-api -- env | grep DD_APPSEC_ENABLED
# Expected: DD_APPSEC_ENABLED=true

# CWS self-tests passed?
kubectl exec -n datadog daemonset/datadog-agent -c security-agent -- \
  security-agent status | grep -A10 "Self Tests"
# Expected: Succeeded: rule_open, rule_chmod, rule_chown — Failed: none
```

#### Finance-specific threat rules (configure in UI)

| Rule | Trigger | Action |
|---|---|---|
| Brute force on `/v1/payments` | > 10 `POST /v1/payments` with 401/422 from same IP in 1m | Block + alert |
| Account enumeration | > 20 `GET /v1/accounts/{id}` 404 from same IP in 1m | Alert |
| High payment velocity | > 5 `POST /v1/payments` from same `account_id` in 1m | Alert |

Docs:
- ASM: https://docs.datadoghq.com/security/application_security/
- CWS: https://docs.datadoghq.com/security/cloud_workload_security/
- CSPM: https://docs.datadoghq.com/security/cloud_security_management/misconfigurations/

---

## `make tf-apply-dd`

### What it does

Applies Terraform under `deploy/terraform/datadog` to create/update live Datadog configuration:

```bash
make tf-apply-dd   # DD_API_KEY / DD_APP_KEY are read from .env automatically
```

| Resource | What it is |
|---|---|
| Log index `finance-logs` | 15-day retention, `kube_namespace:finance` filter |
| Log pipeline | JSON parser + trace ID remapper + service remapper |
| `finance.payment.hits` | Spans metric — `gateway-api` POST /v1/payments |
| `finance.payment.duration` | Distribution spans metric (p95 latency) |
| `finance.fraud.hits` | Spans metric — `fraud-detection` |
| `finance.batch.records_processed` | Spans metric — `batch-processor` |
| `finance.logs.errors` | Logs metric — error count by service |
| 7 monitors | Pod restarts, error rate, payment latency, payment errors, fraud queue, stuck transactions, pods not running |
| 3 SLOs | Payment availability (99.9%), payment latency (99%), fraud consumer (99.5%) |
| Dashboard | Finance App overview (APM, span-based metrics, DBM, ActiveMQ) |
| 7 Synthetic API tests | See below |
| 4 Security monitors | `asm_high_severity_attacks`, `asm_brute_force`, `cws_critical_signal`, `cspm_critical_findings` |

**Not RUM** — RUM is created and owned entirely by `make dem`, above.

All `finance.*` custom metrics referenced here are span-based (`datadog_spans_metric`, generated from the custom spans described in `make instrument` and the always-on spans in `gateway-api`/`fraud-detection`/`batch-processor`) — there is no DogStatsD in this app. Defined in `deploy/terraform/datadog/main.tf`. Docs: https://docs.datadoghq.com/tracing/trace_pipeline/generate_metrics/

### Synthetic tests

Generated from real observed traffic (APM span aggregation on `env:staging`):

| Observed baseline | p95 |
|---|---|
| `GET /health` (all services) | < 6ms |
| `GET /v1/accounts/{id}/balance` | 16ms |
| `POST /v1/payments` | 24ms |
| `POST /v1/accounts` | **575ms** ⚠️ (cold connection pool) |

| # | File | Test | Tier |
|---|---|---|---|
| 1 | `synthetics/health-check.yaml` | Health check — all services | Critical |
| 2 | `synthetics/payment-flow.yaml` | Payment happy path (POST → GET) | Critical |
| 3 | `synthetics/balance-check.yaml` | Authenticated balance check | Critical |
| 4 | `synthetics/unauthenticated-rejection.yaml` | No token → 401 | Security |
| 5 | `synthetics/payment-bad-payload.yaml` | Bad payload → 422 (not 500) | Negative |
| 6 | `synthetics/account-not-found.yaml` | Missing account → 404 | Negative |
| 7 | `synthetics/account-creation-latency.yaml` | Latency baseline (p95=575ms) | Latency |

Every test request carries `x-datadog-trace-id` automatically — click **View Trace** in any test result to jump to the full APM waterfall.

### Reverse it

```bash
make tf-destroy-dd     # WARNING: deletes the log index (and all indexed logs), monitors, dashboard, SLOs
```

### Validate

[Dashboards](https://app.datadoghq.com/dashboard/list) → search `Finance App`.

Docs:
- Synthetic Monitoring: https://docs.datadoghq.com/synthetics/
- Synthetic → APM correlation: https://docs.datadoghq.com/synthetics/apm/

---

## Other signals (always on, not gated by a pipeline stage)

A few signals are neither commented-out-by-default nor controlled by any `make` target above — they come from the base manifests or from `make deploy-k8s`/`make deploy-k8s-dd` unconditionally.

### Structured JSON logs

All six services always emit structured JSON to stdout, collected by the Agent DaemonSet's `/var/log/pods/` volume mount — that part is unconditional, not gated by any `make` target. The Agent-side **collection annotation** that tells it which `source`/`service` to tag those logs with, however, is *not* always-on: it ships commented out and is gated behind `make tags` (step (c) — see [`make tags`](#make-tags) above), e.g.:

```yaml
annotations:
  # ad.datadoghq.com/gateway-api.logs: '[{"source":"python","service":"gateway-api"}]'
```

**Validate:** Log Explorer → `kube_namespace:finance` (logs arrive either way); confirm `source`/`service` faceting only appears correctly once `make tags` has uncommented the annotation and the pod has redeployed.

### ActiveMQ JMX metrics

Applied automatically by `make deploy-k8s-dd`:

```bash
kubectl apply -f deploy/kubernetes/datadog/checks/activemq-check.yaml
```

**Validate:** Infrastructure → Metrics → search `activemq.queue.size`.

> Data Streams Monitoring and Data Jobs Monitoring used to be always-on here too — they're now gated behind `make instrument` (step 4). See [`make instrument`](#make-instrument) above.

> The `ad.datadoghq.com/<service>.logs` annotation used to be always-on here too — it's now gated behind `make tags` (step c). See [`make tags`](#make-tags) above.

---

## Service Catalog: `service.datadog.yaml`

A static, git-committed service metadata file — team ownership (`contacts`), links, lifecycle/tier — the counterpart to what Service Catalog otherwise infers at runtime from APM tags. One file per service, at the root of each service's directory (`gateway-api/service.datadog.yaml`, `account-service/service.datadog.yaml`, `transaction-service/service.datadog.yaml`, `fraud-detection/service.datadog.yaml`, `notification-service/service.datadog.yaml`, `batch-processor/service.datadog.yaml`).

### Schema used in this repo

Confirmed against `gateway-api/service.datadog.yaml` and `notification-service/service.datadog.yaml`:

```yaml
apiVersion: v3
kind: service
metadata:
  name: gateway-api
  displayName: Gateway API
  tags:
    - env:staging
    - language:python
    - team:finance-platform
  links:
    - name: Source
      type: repo
      provider: github
      url: https://github.com/your-org/finance-sample-app/tree/main/gateway-api
  contacts:
    - name: Finance Platform
      type: email
      contact: finance-platform@example.com
spec:
  lifecycle: staging
  tier: High
  type: service
  languages:
    - python
  description: |
    Public-facing REST API. Handles OIDC auth, routes to account-service and transaction-service.
```

`metadata.{name,displayName,tags,links,contacts}` and `spec.{lifecycle,tier,type,languages,description}` — unaffected by Phase A's instrumentation changes.

### How they're loaded

Once Datadog's GitHub integration is installed (**Integrations → GitHub → Repo Configuration → "Link GitHub Account"**), Datadog automatically scans every repository it has read access to for files named `service.datadog.yaml` (and `entity.datadog.yaml`) **anywhere in the repo tree** — not just the root — with no explicit push or CI step required. The API is available as an alternative manual-import path for teams not using the GitHub integration.

---

## Makefile targets

Instrumentation-lifecycle targets only. For build/deploy/AWS-infrastructure targets, see the [README](../README.md).

| Target | What it does |
|---|---|
| `make tags` | Enable Unified Service Tagging + log injection (all 6 manifests) via patches |
| `make untag` | Reverse all Tags + log-injection patches |
| `make dbm` | Enable Database Monitoring — Agent-side config + PostgreSQL `datadog` role |
| `make undbm` | Reverse Database Monitoring — drops the PostgreSQL role, reverses Agent-side config |
| `make instrument` | Enable APM custom spans + Single Step Instrumentation gating + Continuous Profiler via patches |
| `make uninstrument` | Reverse all `make instrument` patches |
| `make dem` | Create the Browser RUM application via a direct Datadog API call and inject credentials into `frontend-stub/index.html`. Idempotent (`.dem-applied` + `.dem-state.json`) |
| `make undem` | Delete the RUM application via the Datadog API; restore frontend RUM placeholder tokens |
| `make security` | Enable ASM Threats/SCA, CWS, CSPM — Agent-side config + `DD_APPSEC_ENABLED` on all 6 services |
| `make unsecurity` | Reverse all `make security` patches |
| `make tf-apply-dd` | Apply Datadog Terraform resources (monitors, SLOs, dashboard, synthetics, log pipeline) |
| `make tf-destroy-dd` | Destroy Datadog Terraform resources |

> **Port-forward note:** `make test` and `make test-traffic` connect to services from your laptop and need manual port-forwards first — see the [README](../README.md) for the commands. You normally don't need either: the in-cluster `traffic-generator` Deployment already generates continuous traffic with no port-forward needed for Datadog telemetry.
