# Meridian Financial — Troubleshooting Guide

When something isn't working, resist the urge to chase the first error message
you see. This app has six layers between "I ran a command" and "I see data in
Datadog," and a failure in an early layer often produces a confusing symptom
in a much later one (e.g. a Keycloak secret mismatch shows up as "no traces in
APM," not as an auth error).

Work through the layers **in order**. Confirm each one is healthy before
investigating the next — this avoids debugging a real problem in Layer 5 when
the actual root cause is a broken Layer 2.

```
Infrastructure → Application → Identity → Instrumentation → Telemetry → Backend
```

| # | Layer | Question |
|---|---|---|
| 1 | Infrastructure | Is Kubernetes healthy? |
| 2 | Application | Is the application healthy? |
| 3 | Identity | Is authentication working? |
| 4 | Instrumentation | Was instrumentation injected? |
| 5 | Telemetry | Is telemetry reaching the Agent? |
| 6 | Backend | Is Datadog ingesting the data? |

---

## 1 — Infrastructure: Is Kubernetes healthy?

```bash
kubectl get nodes                    # all Ready
kubectl get pods -n finance          # all Running (12 pods, incl. traffic-generator)
kubectl get pods -n datadog          # Agent DaemonSet + Cluster Agent Running
kubectl get events -n finance --sort-by='.lastTimestamp' | tail -20
```

**Common failures at this layer:**
- Pods stuck in `Pending` — usually insufficient CPU/memory on the local
  cluster (Docker Desktop/Colima resource limits) or, on EKS, a node group
  that hasn't scaled up yet.
- Pods `CrashLoopBackOff` — check `kubectl logs -n finance <pod> --previous`.
  If it's the Datadog Operator specifically, see
  [deploy/kubernetes/datadog/README.md](./deploy/kubernetes/datadog/README.md)
  for the `maximumGoroutines` fix.
- `ImagePullBackOff` on local — you likely skipped the image-load step for
  your local Kubernetes tool (kind/k3d/minikube/Colima all require it; Docker
  Desktop/Rancher Desktop don't). See root README's Prerequisites.

**Do not proceed past this layer** until every pod in both namespaces is
`Running`. Everything downstream assumes a healthy cluster.

---

## 2 — Application: Is the application healthy?

```bash
kubectl exec -n finance deploy/gateway-api -- curl -s localhost:8080/health
kubectl port-forward svc/gateway-api 8080:8080 -n finance &
curl -s http://localhost:8080/health
```

**Common failures at this layer:**
- `500` errors on `/health` — check the failing service's own logs
  (`kubectl logs -n finance deploy/<service>`) for a stack trace. This is
  almost always a real application bug, not a Datadog problem — rule it out
  before assuming instrumentation broke something.
- A service can't reach PostgreSQL/ActiveMQ/Redis — check the init containers
  (`wait-for-postgres`, `wait-for-activemq`) completed:
  `kubectl logs -n finance <pod> -c wait-for-postgres`.
- ActiveMQ STOMP messages silently never arrive at a consumer — this is a
  broker-side address-naming mismatch (`anycastPrefix`/`multicastPrefix`),
  not an application bug. See the comment header in
  `deploy/kubernetes/base/infrastructure/activemq-broker-config.yaml`.

---

## 3 — Identity: Is authentication working?

```bash
# From the finance namespace, log in as a real user and confirm you get a token:
kubectl run -it --rm curl-test --image=curlimages/curl -n finance --restart=Never -- \
  curl -s -X POST http://keycloak:8080/realms/finance/protocol/openid-connect/token \
    -d grant_type=password -d client_id=finance-gateway \
    -d client_secret=<real-secret-from-app-secrets> \
    -d username=carol.admin -d password='Finance@2025!'
```

**Common failures at this layer:**
- `invalid_client_credentials` (401) — the caller's `KEYCLOAK_CLIENT_SECRET`
  doesn't match the real secret. The in-cluster `traffic-generator` reads it
  correctly from the `app-secrets` K8s Secret automatically; if you're
  running `scripts/generate-traffic.py` or `scripts/test-e2e.py` manually from
  your laptop, make sure `KEYCLOAK_CLIENT_SECRET` is exported from the real
  secret (`kubectl get secret app-secrets -n finance -o jsonpath='{.data.keycloak-client-secret}' | base64 -d`),
  not left at the `REPLACE_WITH_SECRET` placeholder default.
- Browser login redirects to the wrong host / cookie errors — `KEYCLOAK_PUBLIC_URL`
  in the `app-config` ConfigMap doesn't match how you're actually reaching the
  app (localhost vs. the EKS NLB hostname). See root README's Identity
  Provider section.
- **A failure here is very often mistaken for an instrumentation or telemetry
  problem** — a payment request that 401s never generates the `ledger.commit`
  span you were expecting to see in APM, but the "missing span" is a symptom,
  not the cause. Always confirm auth is working (Layer 3) before debugging
  "why don't I see this span" (Layer 4/5).

---

## 4 — Instrumentation: Was instrumentation injected?

```bash
# Init containers present? (Admission Controller auto-injection, Single Step Instrumentation)
kubectl get pod -n finance -l app=gateway-api \
  -o jsonpath='{.items[0].spec.initContainers[*].name}'
# Expected: datadog-lib-python-init datadog-init-apm-inject
# (datadog-lib-java-init / -js-init / -go-init for the other services)

# Required label present on the pod template?
kubectl get pod -n finance -l app=gateway-api \
  -o jsonpath='{.items[0].metadata.labels.admission\.datadoghq\.com/enabled}'
# Expected: true

# Tracer actually loaded inside the container?
kubectl exec -n finance deploy/gateway-api -- env | grep DD_INSTRUMENTATION_INSTALL_TYPE
# Expected: DD_INSTRUMENTATION_INSTALL_TYPE=k8s_lib_injection (or similar)
```

**Common failures at this layer:**
- Init containers missing entirely — the Admission Controller webhook isn't
  reaching the pod. This has `failurePolicy: Ignore`, so pods still start
  successfully with **no error at all** — the only symptom is instrumentation
  silently not happening. See
  [INSTRUMENTATION.md's Admission Controller troubleshooting](./INSTRUMENTATION.md#admission-controller-injection-not-working).
- On EKS specifically: the control plane can't reach the Cluster Agent's
  webhook on node port 8000 — check the node security group has the
  `ingress_cluster_8000_datadog_admission_webhook` rule (see
  `deploy/terraform/aws/main.tf`).
- `make instrument` (In-depth instrumentation — APM custom spans only) reports patch
  failures or `.rej` files — this means the patch files are stale relative to the
  current source. Regenerate them: `python3 scripts/generate-patches.py`,
  then re-run `make instrument`. It's idempotent — running it twice in a row
  is a safe no-op (tracked via `.instrumentation-applied`).
  RUM/DEM issues are separate — see `make dem`/`make undem` in INSTRUMENTATION.md.
- `make dbm` / `make security` report patch failures — same idempotent pattern as
  `make instrument` (`patch -p1 --forward -s`, tracked via `.dbm-applied` /
  `.security-applied`). Run `make undbm` / `make unsecurity` first to force a
  clean re-comment attempt, then re-run `make dbm` / `make security`. Unlike
  `make instrument`, these two aren't regenerated by `scripts/generate-patches.py`
  (`dbm-agent.patch`, `agent-security.patch`, and the `appsec-*.patch` files patch
  `datadog-agent.yaml` and manifests, not app source) — if a patch is genuinely
  stale, edit the unified diff under `scripts/patches/dbm/` or
  `scripts/patches/security/` by hand.

---

## 5 — Telemetry: Is telemetry reaching the Agent?

```bash
# From inside a service pod, can it reach the node's Agent?
kubectl exec -n finance deploy/gateway-api -- env | grep DD_AGENT_HOST
DD_HOST=$(kubectl exec -n finance deploy/gateway-api -- env | grep DD_AGENT_HOST | cut -d= -f2)
kubectl exec -n finance deploy/gateway-api -- wget -qO- http://$DD_HOST:8126/info

# Is the Agent actually receiving anything?
kubectl exec -n datadog daemonset/datadog-agent -c trace-agent -- \
  agent status | grep -A5 "Traces received"
```

**Common failures at this layer:**
- `DD_AGENT_HOST` unset or pointing at the wrong address — should resolve via
  the Downward API to `status.hostIP` (the node running the pod), not
  `localhost` or a hardcoded IP.
- Agent DaemonSet pod on that specific node isn't `Running` — traces from
  pods scheduled on a broken node never reach any Agent, while pods on
  healthy nodes work fine. Check `kubectl get pods -n datadog -o wide` and
  compare node names against the failing service's pod.
- Agent integration checks failing (DBM, ActiveMQ JMX) —
  `kubectl exec -n datadog daemonset/datadog-agent -c agent -- agent status`.
  `'no valid instances'` means the check YAML in
  `deploy/kubernetes/datadog/checks/` needs review; `'authentication failed'`
  means the DBM/JMX credentials in the `datadog-secret` are wrong.

---

## 6 — Backend: Is Datadog ingesting the data?

```bash
# API key valid?
curl -s "https://api.datadoghq.com/api/v1/validate" -H "DD-API-KEY: ${DD_API_KEY}"
# Expected: {"valid":true}
```

**Common failures at this layer:**
- `{"valid":false}` — `DD_API_KEY` is wrong, or you copied the **Application
  Key ID** instead of the **Application Key value** for `DD_APP_KEY` (these
  are different things — the Datadog UI's Application Keys page prominently
  shows the Key ID, which is *not* what Terraform needs). See root README's
  Prerequisites for a visual example of the difference.
- Data reaches the Agent (Layer 5 confirmed OK) but never appears in the UI —
  check `DD_SITE` matches your org's actual site (`datadoghq.com` vs.
  `datadoghq.eu` vs. `us3.datadoghq.com`, etc.) in both the Agent config and
  `deploy/terraform/datadog/staging.tfvars`.
- `terraform plan`/`apply` fails with a provider schema error (e.g. unknown
  attribute) — the Datadog Terraform provider version has drifted from what
  the resource blocks expect. Pin the provider version explicitly in
  `deploy/terraform/datadog/main.tf`'s `required_providers` block and re-run
  `terraform init -upgrade=false`.
- `terraform plan`/`apply` fails immediately with `Failed to read variables
  file` — `staging.tfvars` doesn't exist yet. This self-heals automatically
  now (`make tf-plan-dd`/`tf-apply-dd` auto-copy from `staging.tfvars.example`
  on first use) — if you still hit this, you're likely calling `terraform`
  directly instead of through `make`.

---

## Quick reference: which layer explains this symptom?

| Symptom | Most likely layer |
|---|---|
| Pod won't start | 1 — Infrastructure |
| `curl /health` fails or times out | 2 — Application |
| `401` / `invalid_client_credentials` on any request | 3 — Identity |
| Service works fine but no traces at all in APM | 4 — Instrumentation |
| One service's traces work, another's don't | 4 — Instrumentation (check that specific pod's init containers) |
| Traces flow for most requests but randomly stop | 5 — Telemetry (check Agent pod on that node) |
| Everything "looks connected" but nothing shows up in the Datadog UI | 6 — Backend (API key / site / provider version) |
| `terraform plan`/`apply` fails before touching any real infrastructure | 6 — Backend (config/provider issue, not a live-environment issue) |

## See also

- [INSTRUMENTATION.md](./INSTRUMENTATION.md) — full step-by-step instrumentation guide, with its own per-step `Validate:` checks and a dedicated Troubleshooting section for Admission Controller / APM / Agent-check / patch failures.
- [README.md](./README.md) — Quick Start, Adding Datadog, and Traffic Generator sections each have a "✅ Verify before continuing" checklist for the corresponding stage.
