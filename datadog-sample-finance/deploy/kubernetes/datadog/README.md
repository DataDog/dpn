# Adding Datadog to the Kubernetes Deployment

This directory contains the Datadog Agent/Operator resources for the Finance
sample app on Kubernetes. **In practice, `make deploy-k8s-dd` runs everything
in this doc for you** (Operator install, secret creation, Agent CRD, and the
two check ConfigMaps) — read on if you want to understand or customize what
it does, or to use Helm directly instead of the Operator.

**Prerequisite:** the base application must already be running:
```bash
make deploy-k8s
kubectl get pods -n finance   # all 12 pods should be Running (incl. traffic-generator)
```

> **Single Step Instrumentation ships on by default.** Unlike an older design this
> project used, `admission.datadoghq.com/enabled: "true"`, the
> `tags.datadoghq.com/*` Unified Service Tagging labels, and the `DD_ENV` /
> `DD_SERVICE` / `DD_VERSION` env vars are already present in every base
> Deployment under `../base/services/` — there is no separate "patched"
> manifest to apply. Once the Agent (below) is running, APM traces start
> flowing immediately with zero further changes.

---

## What is deployed

| Resource | Purpose |
|---|---|
| `agent/datadog-agent.yaml` | `DatadogAgent` CRD — Operator installs Node Agent DaemonSet + Cluster Agent |
| `agent/helm-values.yaml` | Alternative Helm chart values (if not using the Operator) |
| `checks/postgres-check.yaml` | DBM Agent check ConfigMap (commented out — see Step 4) |
| `checks/activemq-check.yaml` | ActiveMQ JMX Agent check ConfigMap (commented out — see Step 4) |
| `secrets/datadog-secrets.yaml` | Secret template documenting GitOps alternatives (Sealed Secrets, SOPS, External Secrets Operator) |
| `services/catalog-sync.yaml` | Optional Service Catalog entity-file scanner — not wired into any `make` target; apply manually if you want it |

---

## Step 1 — Install the Datadog Operator

The Datadog Operator manages the Agent DaemonSet and Cluster Agent via a single
`DatadogAgent` CRD. It is the recommended production install path.

```bash
helm repo add datadog https://helm.datadoghq.com
helm repo update

helm install datadog-operator datadog/datadog-operator \
  --namespace datadog \
  --create-namespace \
  --set watchNamespaces="{datadog,finance}" \
  --set maximumGoroutines=800
```

> `maximumGoroutines=800` avoids a crash-loop on the Operator's internal
> goroutine health check — without it the Operator pod restarts continuously.

Verify the Operator is running:
```bash
kubectl get pods -n datadog
```

> **Helm alternative:** skip the Operator and use `agent/helm-values.yaml` directly.
> See [Helm alternative](#helm-alternative-without-the-operator) below.

---

## Step 2 — Create the Datadog Secret

**Never pass API/App keys as plain values.** Create a Kubernetes Secret with
all three keys the Agent needs (`api-key`, `app-key`, `dbm-password`):

```bash
kubectl create secret generic datadog-secret \
  --namespace datadog \
  --from-literal api-key=<YOUR_DATADOG_API_KEY> \
  --from-literal app-key=<YOUR_DATADOG_APP_KEY> \
  --from-literal dbm-password=<YOUR_DBM_MONITORING_PASSWORD>
```

Or let `make create-dd-secret` do this for you — it auto-detects local (reads
`.env`) vs EKS (reads AWS Secrets Manager). See `INSTRUMENTATION.md`'s
[Datadog secrets section](../../../INSTRUMENTATION.md#datadog-secrets--datadog-secret-k8s-secret)
for the full explanation and GitOps alternatives (`secrets/datadog-secrets.yaml`
documents Sealed Secrets / SOPS / External Secrets Operator templates).

---

## Step 3 — Deploy the Datadog Agent

Apply the `DatadogAgent` CRD. The Operator creates the Node Agent DaemonSet,
Cluster Agent Deployment, and all required RBAC resources automatically.

```bash
kubectl apply -f deploy/kubernetes/datadog/agent/datadog-agent.yaml
```

Verify the rollout (takes 1–2 minutes):
```bash
kubectl get datadogagent -n datadog
kubectl get daemonset datadog -n datadog
kubectl get deployment datadog-cluster-agent -n datadog
```

Or use the Makefile shortcut, which also runs Steps 1, 2, and 4 automatically
and patches the config for EKS/Bottlerocket when needed:
```bash
make deploy-k8s-dd
```

---

## Step 4 — Apply Agent Check ConfigMaps (optional)

These ConfigMaps provide the Datadog Agent with check configurations for
PostgreSQL (DBM) and ActiveMQ. The content is entirely commented out by default —
uncomment each block when you are ready to enable the check.

```bash
kubectl apply -f deploy/kubernetes/datadog/checks/
```

Then mount the ConfigMaps into the Agent by adding a volume/volumeMount override
to `agent/datadog-agent.yaml` (the comments in each ConfigMap file show the exact
override block to add).

---

## Helm alternative (without the Operator)

If you prefer Helm directly over the Operator:

```bash
# Create the namespace and Secret first (see Step 2 above)
kubectl create namespace datadog

helm install datadog datadog/datadog \
  --namespace datadog \
  -f deploy/kubernetes/datadog/agent/helm-values.yaml
```

`agent/helm-values.yaml` mirrors all features in `agent/datadog-agent.yaml` and
includes the same commented-out options for security, profiler, and CSPM.

---

## Unified Service Tagging

Already applied to every service in `../base/services/`. All pods carry these
three labels so Datadog can correlate telemetry across traces, logs, metrics,
and profiles:

```yaml
labels:
  tags.datadoghq.com/env:     staging
  tags.datadoghq.com/service: gateway-api
  tags.datadoghq.com/version: "latest"
```

And the matching env vars inside the container:
```yaml
env:
  - name: DD_ENV
    value: "staging"
  - name: DD_SERVICE
    value: "gateway-api"
  - name: DD_VERSION
    value: "latest"
```

Reference: https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging/

---

## Admission Controller

The Cluster Agent's Admission Controller is enabled by default in
`datadog-agent.yaml`. Every base Deployment under `../base/services/` already
carries:

```yaml
annotations:
  admission.datadoghq.com/enabled: "true"
```

which causes the Admission Controller to **automatically inject** the tracer
library, `DD_AGENT_HOST`, `DD_TRACE_AGENT_URL`, and `DD_ENTITY_ID` into the pod
at admission time — no manual patching of any service manifest is needed.

Reference: https://docs.datadoghq.com/containers/cluster_agent/admission_controller/

---

## Learning Progression

Follow these steps in order to progressively enable observability on the K8s
deployment. Numbering matches `INSTRUMENTATION.md`'s step-by-step breakdown and
each service's own README.

| Step | Action | Datadog product |
|---|---|---|
| 1 | Complete Steps 1–3 above (Operator + Agent) | Infrastructure List, Container Map |
| 2 | Confirm Unified Service Tags on all Deployments (already applied) | APM, Logs, Metrics correlation |
| 3 | Verify APM traces appear (automatic — Admission Controller injection) | APM > Services |
| 4 | Verify `trace_id` appears in logs (automatic with Single Step Instrumentation) | Log Management |
| 5 | `make instrument` — custom spans in business-critical code paths | APM flame graphs |
| 6 | `make instrument` — DogStatsD metric calls | Metrics Explorer |
| 7 | Enable Continuous Profiler (`DD_PROFILING_ENABLED=true`) | Continuous Profiler |
| 8 | `make dem` — Browser RUM + Session Replay | RUM |
| 9 | Apply DBM ConfigMap + PostgreSQL prerequisites (Step 4 above) | Databases > Query Metrics |
| 10 | Apply ActiveMQ ConfigMap + enable DSM (Step 4 above) | Data Streams |
| 11 | `make tf-apply-dd` — monitors, SLOs, dashboard, synthetics | Monitors, Dashboards |
| 12 | Synthetic API tests (included in `make tf-apply-dd`) | Synthetics |
| 13 | ASM + CWS + CSPM (already enabled — see `agent/datadog-agent.yaml`) | Security |

---

## Key References

See [INSTRUMENTATION.md's Key references](../../../INSTRUMENTATION.md#key-references)
for the full Datadog documentation table. Links unique to this file:

| Topic | URL |
|---|---|
| APM on Kubernetes | https://docs.datadoghq.com/containers/kubernetes/apm/ |
| Log collection (Kubernetes) | https://docs.datadoghq.com/containers/kubernetes/log/ |
