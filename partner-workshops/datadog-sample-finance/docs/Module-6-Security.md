# Module 6 — Security (`make security`)

## Overview

`make security` turns on ASM (Threats + Software Composition Analysis), Cloud Workload Security
(CWS), and Cloud Security Posture Management (CSPM) — all agent-side, with no application logic
changes beyond a single feature-flag env var per service. Worth positioning as a "free" upsell
once APM is already in place: the tracer that's already injected (Module 4) is what ASM Threats
actually instruments.

**Learning Objectives**
- Understand the two-sided nature of `make security` (Agent config + app-side flag)
- Distinguish what each of ASM Threats, ASM SCA, CWS, and CSPM actually detects
- Enable the stage and confirm CWS self-tests pass

**Recommended Duration:** 30–45 minutes

**Prerequisites:** Module 4 complete — ASM Threats needs the tracer already injected via Single
Step Instrumentation to have anything to attach to.

## Section 1 — What `make security` Does

Two narrated steps, one sentinel (`.security-applied`):

- **(a) Agent-side** — `security/agent-security.patch` uncomments the `asm`/`cws`/`cspm` feature
  blocks in `datadog-agent.yaml`:
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
- **(b) App-side** — `security/appsec-<service>.patch` (all 6 services) uncomments each
  service's `DD_APPSEC_ENABLED` env entry.

## Section 2 — What's Enabled

| Product | Layer | Detects |
|---|---|---|
| ASM Threats | APM tracer (app-side) | SQLi, XSS, SSRF, credential stuffing, business-logic attacks |
| ASM SCA | Agent-side | Known CVEs in Python/Java/Node.js/Go dependencies |
| CWS | Agent eBPF (kernel) | Shell spawned in container, file writes, privilege escalation, syscall anomalies |
| CSPM | Agent + cloud APIs | Privileged pods, exposed secrets, insecure RBAC, CIS/PCI-DSS findings |

## Section 3 — Why It Matters

The Agent features turn on the threat-intake pipeline, eBPF runtime monitoring, and CIS benchmark
checks; the tracer needs `DD_APPSEC_ENABLED=true` to actually instrument requests for the
app-layer threats (SQLi/XSS/SSRF/business-logic).

## Section 4 — Workflow

```bash
make security
# Redeploy to activate:
#   Agent: kubectl apply -k deploy/kubernetes/datadog/agent && kubectl rollout restart daemonset/datadog-agent -n datadog
#   Apps:  make build && load images into k3s && make deploy-k8s
#          (a bare rollout restart won't pick up the new DD_APPSEC_ENABLED env var)
```

> **EKS:** replace the Apps line with `make build-ecr && make deploy-k8s-eks`.

**Reverse it:**
```bash
make unsecurity          # restores every file to its original commented-out state
```

## Validate

```bash
kubectl exec -n finance deploy/gateway-api -- env | grep DD_APPSEC_ENABLED
# Expected: DD_APPSEC_ENABLED=true

kubectl exec -n datadog daemonset/datadog-agent -c security-agent -- security-agent status | grep -A10 "Self Tests"
# Expected: Succeeded: rule_open, rule_chmod, rule_chown — Failed: none
```

### Finance-specific threat rules (configure in the UI)

| Rule | Trigger | Action |
|---|---|---|
| Brute force on `/v1/payments` | > 10 `POST /v1/payments` with 401/422 from same IP in 1m | Block + alert |
| Account enumeration | > 20 `GET /v1/accounts/{id}` 404 from same IP in 1m | Alert |
| High payment velocity | > 5 `POST /v1/payments` from same `account_id` in 1m | Alert |

## Practical Exercise

**Goal:** Enable all four security products and confirm both the Agent-side and app-side halves
independently.

**Time:** 20–30 minutes

**Steps:**
1. `make security` + redeploy both the Agent and the apps per the workflow above.
2. Confirm `DD_APPSEC_ENABLED=true` on `gateway-api`.
3. Run the CWS self-test check and confirm all three rules succeeded.
4. Configure at least one of the three finance-specific threat rules above in the UI.
5. Reverse it: `make unsecurity` and confirm the env var disappears.

**Expected outcome:** Both halves of `make security` independently confirmed, plus one live
custom threat rule configured for Meridian Financial.

## Resources & Next Steps

- Application Security (ASM): https://docs.datadoghq.com/security/application_security/
- Cloud Workload Security (CWS): https://docs.datadoghq.com/security/cloud_workload_security/
- Cloud Security Posture Management (CSPM): https://docs.datadoghq.com/security/cloud_security_management/misconfigurations/
- `sample/impl/INSTRUMENTATION.md` — `make security` section

**Next module**: [Module 7 — Dashboards, Monitors & the Diagnosis Lab (`make tf-apply-dd`)](Module-7-Dashboards-Monitors-Diagnosis-Lab.md)
