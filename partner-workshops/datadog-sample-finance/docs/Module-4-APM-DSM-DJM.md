# Module 4 — APM, Data Streams & Data Jobs Monitoring (`make instrument`)

## Overview

`make instrument` is the largest single stage in the pipeline — it applies four narrated steps
under one sentinel (`.instrumentation-applied`): APM custom spans, Single Step Instrumentation
gating, Continuous Profiler, and Data Streams / Data Jobs Monitoring. Reversing
(`make uninstrument`) runs the same four steps in the opposite order.

**Learning Objectives**
- Understand which spans are always-on vs. patch-gated, per service
- Enable Single Step Instrumentation and verify tracer injection actually happened
- Enable the Continuous Profiler and correlate a flame graph with a slow trace
- Understand Data Streams Monitoring's producer-vs-consumer distinction, including a real gap in
  library coverage this app hits (STOMP)
- Understand what Data Jobs Monitoring adds on top of a Spring Batch job's own status field

**Recommended Duration:** 1.5–2 hours (this is the densest module — budget accordingly)

**Prerequisites:** Modules 2 and 3 complete.

**No DogStatsD anywhere in this app.** Every `finance.*` custom metric referenced in this module
is span-based (`datadog_spans_metric`, applied via Module 7's `make tf-apply-dd`) — generated
directly from the spans below, not from a separate metrics client.

## Step 1 — APM Custom Spans

`scripts/patches/*.patch` (top-level directory only):

| Target | Mechanism | What it enables |
|---|---|---|
| `gateway-api` | `gateway-api.patch` | Uncomments `import ddtrace.profiling.auto`, `from ddtrace import patch_all, tracer`, and `patch_all()` in `main.py`, plus the `payment.authorize` / `account.balance_check` custom spans — all in the same patch. No pip dependency is added here; see the SSI note in Step 2 below |
| `fraud-detection` | `fraud-detection.patch` | Uncomments `from ddtrace import patch_all`, `patch_all()`, `import ddtrace.profiling.auto` in `main.py`, plus `from ddtrace import tracer` and the `fraud.score` custom span in `listener.py` — same no-pip-dependency note as `gateway-api` |
| `transaction-service` | `transaction-service.patch` | Uncomments the dd-trace APM init in `index.js`, adds `dd-trace` back to `package.json`, and the `payment.authorize` custom span in `payments.js` |
| `notification-service` | `notification-service.patch` | Uncomments `tracer.Start()` (APM), `profiler.Start()` (Continuous Profiler), and the `alert.send` custom span in `main.go` — all three in the same source banner |

**Already active in source — no patch, always on:** `batch-processor` (`job.name` / `job.status` /
`job.records_processed` span tags). `account-service` has no custom instrumentation — Java agent
auto-instrumentation only.

**Validate:** APM → Traces → filter `resource_name:payment.authorize` or
`operation_name:alert.send`.

## Step 2 — Single Step Instrumentation Gating

`scripts/patches/instrument-sso/sso-*.patch` uncomments, on all six manifests, the pod
label/annotation pair that opts a pod into the Admission Controller's tracer injection:

```yaml
labels:
  admission.datadoghq.com/enabled: "true"
annotations:
  admission.datadoghq.com/python-lib.version: "v2"     # gateway-api, fraud-detection
  admission.datadoghq.com/js-lib.version: "v5"         # transaction-service
  admission.datadoghq.com/java-lib.version: "v1"       # account-service, batch-processor
  admission.datadoghq.com/go-lib.version: latest       # notification-service (no-op — see below)
```

| Service | Library | Injection mechanism |
|---|---|---|
| `gateway-api` | `ddtrace` (Python) | `PYTHONPATH` + auto-instrumentation |
| `fraud-detection` | `ddtrace` (Python) | same |
| `transaction-service` | `dd-trace` (Node.js) | `NODE_OPTIONS=--require dd-trace/init` |
| `account-service` | `dd-java-agent` (Java) | `JAVA_TOOL_OPTIONS=-javaagent:...` |
| `batch-processor` | `dd-java-agent` (Java) | same |
| `notification-service` | `dd-trace-go` (Go) | **not single-step injected** — Go tracing comes entirely from Step 1's in-code `tracer.Start()` |

> **Nuance worth teaching explicitly:** the two Python services deliberately have **no** `ddtrace`
> pin in their own `requirements.txt` at all — SSI's injected library (via `PYTHONPATH`) is the
> *only* source of `ddtrace` for them, with nothing baked into the image to shadow it. This also
> means Step 1's uncommented `ddtrace` imports and custom spans in `main.py`/`listener.py` only
> actually work once the Datadog Operator/Admission Controller is installed (`make deploy-k8s-dd`)
> and the pod has been redeployed — Step 1 alone (without SSI actually running) leaves those
> imports unresolvable.

**Verify injection:**
```bash
kubectl get pod -n finance -l app=gateway-api -o jsonpath='{.items[0].spec.initContainers[*].name}'
# Expected: datadog-lib-python-init datadog-init-apm-inject
kubectl exec -n finance deploy/gateway-api -- env | grep DD_INSTRUMENTATION
# Expected: DD_INSTRUMENTATION_INSTALL_TYPE=k8s_lib_injection
```

If injection silently doesn't happen: the webhook has `failurePolicy: Ignore`, so pods still
start with **no error at all** — check `kubectl logs -n datadog deploy/datadog-cluster-agent |
grep -i admission` first, not the app pod's own logs.

## Step 3 — Continuous Profiler

`scripts/patches/instrument-sso/profiler-*.patch` uncomments `DD_PROFILING_ENABLED=true` on 5 of
6 services (all except `notification-service`, whose Go profiler is already gated by Step 1's
patch in the same source banner as its APM tracer).

**Validate:** APM → Profiles — flame graphs appear within ~1 minute. Correlates CPU flame graphs
directly with slow payment traces or slow batch job steps.

## Step 4 — Data Streams / Data Jobs Monitoring

`scripts/patches/instrument-sso/dsm-*.patch` + `djm-batch-processor.patch` uncomments
`DD_DATA_STREAMS_ENABLED=true` on the four JMS services (`account-service`,
`transaction-service`, `fraud-detection`, `notification-service`) and
`DD_DATA_JOBS_ENABLED=true` on `batch-processor`. `gateway-api` has neither — it doesn't touch
JMS.

DSM gives producer→consumer latency and consumer-lag visibility across the payment → fraud →
notification flow. `account-service`'s JMS producer/consumer checkpoints are auto-instrumented by
dd-trace-java. **`transaction-service` is different, and worth teaching as its own point:**

> **The STOMP gap.** `transaction-service` publishes to `fraud.score.queue` over the JMS broker
> using the `stompit` library — and dd-trace Node.js has **no automatic STOMP instrumentation at
> all**. Without extra work, `transaction-service` never appears as a producer in the DSM pathway
> map, no matter how much traffic it generates. This patch closes that gap with a **manual DSM
> checkpoint** — `tracer.dataStreamsCheckpointer.setProduceCheckpoint(...)` in
> `transaction-service/src/messaging/producer.js` — plus a matching manual consume checkpoint in
> `fraud-detection/listener.py`. This is the mechanism, not a hypothetical: Module 7's diagnosis
> lab Scenario 3 depends entirely on this checkpoint being in place, or the scenario's producer
> never shows up in the pathway map at all.

> **`fraud-detection` needs a rebuild, not just a redeploy.** Its DSM support is a baked pip
> dependency (`ddtrace[data_streams]` in `requirements.txt`), unlike the other three services'
> plain env-var toggle. After `make instrument`, `fraud-detection` specifically needs `make build`
> (or `make build-ecr`) + image reload before DSM data appears.

DJM surfaces Spring Batch job runs under APM → Data Jobs — primarily built for Spark/Databricks
workloads, so for a plain Spring Batch app the Step 1 APM spans + `job.*` tags already cover most
needs; DJM adds the run-history timeline on top.

**Validate:** Data Streams → pathway map shows `fraud.score.queue` and `alert.queue`. APM → Data
Jobs after a reconciliation run.

## Workflow

```bash
make instrument          # applies all 4 steps
make build                # rebuild the service images
# → reload the rebuilt images into your cluster (Colima/kind/k3d/minikube need this; Docker
#   Desktop/Rancher Desktop don't)
make deploy-k8s           # re-applies the patched manifests — a bare rollout restart won't
                           # pick up new env vars/labels/annotations
```

> **EKS:** replace `make build` + `make deploy-k8s` with `make build-ecr && make deploy-k8s-eks`.

**Reverse it:**
```bash
make uninstrument       # reverses in opposite order: DSM/DJM → profiler → SSI gating → APM spans
make build
```

## Practical Exercise

**Goal:** Enable all four steps, verify each one independently, and specifically confirm the
STOMP/DSM manual-checkpoint gap by checking `transaction-service` appears as a producer.

**Time:** 45–60 minutes

**Steps:**
1. `make instrument && make build` (+ reload images if needed) `&& make deploy-k8s`.
2. Confirm the `payment.authorize` and `alert.send` custom spans in APM → Traces.
3. Verify Single Step Instrumentation injected correctly on `gateway-api` (init containers +
   `DD_INSTRUMENTATION_INSTALL_TYPE`).
4. Confirm flame graphs appear in APM → Profiles for at least one service.
5. Rebuild `fraud-detection` specifically (`make build`) if DSM data hasn't appeared for it after
   a few minutes.
6. Open Data Streams → pathway map for `fraud.score.queue` — confirm `transaction-service`
   appears as a producer (not just `fraud-detection` as consumer). If it doesn't, this is the
   diagnostic muscle memory Module 7's Scenario 3 will test directly.
7. Trigger a reconciliation run and confirm it appears under APM → Data Jobs.

**Expected outcome:** All four sub-signals independently verified, with the STOMP/DSM checkpoint
explicitly confirmed working — this is the prerequisite Module 7's capstone scenario depends on.

## Resources & Next Steps

- Custom instrumentation: https://docs.datadoghq.com/tracing/trace_collection/custom_instrumentation/
- Single-step instrumentation: https://docs.datadoghq.com/tracing/trace_collection/automatic_instrumentation/single-step-apm/
- Continuous Profiler: https://docs.datadoghq.com/profiler/
- Data Streams Monitoring: https://docs.datadoghq.com/data_streams/
- Data Streams — Node.js manual checkpoints: https://docs.datadoghq.com/data_streams/nodejs/
- Data Jobs Monitoring: https://docs.datadoghq.com/data_jobs/
- `sample/impl/INSTRUMENTATION.md` — `make instrument` section, full patch-by-patch detail

**Next module**: [Module 5 — Real User Monitoring (`make dem`)](Module-5-Real-User-Monitoring.md)
