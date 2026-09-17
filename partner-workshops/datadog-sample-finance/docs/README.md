# DPN Implementation Workshop — Meridian Financial Curriculum

Partner-training curriculum for the hands-on lab in this repo (`sample/impl`), organized around
the actual `make` pipeline instead of Datadog product pillars — each module maps to one real
pipeline stage, so "what did we just do" always has a concrete answer: the `make` target you ran.

## Module Index

| # | Module | Pipeline stage | Focus |
|---|---|---|---|
| 0 | [Project & Customer Scoping](Module-0-Project-Scoping.md) | — (pre-`make`) | Read the architecture, propose, prioritize |
| 1 | [Foundation & Deploy](Module-1-Foundation-and-Deploy.md) | `make build` / `deploy-k8s` / `deploy-k8s-dd` | Org setup + cold deploy, zero instrumentation |
| 2 | [Unified Service Tagging](Module-2-Unified-Service-Tagging.md) | `make tags` | Tag taxonomy, log-trace correlation |
| 3 | [Database Monitoring](Module-3-Database-Monitoring.md) | `make dbm` | Query metrics, explain plans, APM↔DBM |
| 4 | [APM, Data Streams & Data Jobs Monitoring](Module-4-APM-DSM-DJM.md) | `make instrument` | Custom spans, SSI, Profiler, DSM, DJM |
| 5 | [Real User Monitoring](Module-5-Real-User-Monitoring.md) | `make dem` | Browser RUM, Session Replay, PII masking |
| 6 | [Security](Module-6-Security.md) | `make security` | ASM, CWS, CSPM |
| 7 | [Dashboards, Monitors & the Diagnosis Lab](Module-7-Dashboards-Monitors-Diagnosis-Lab.md) | `make tf-apply-dd` | Dashboards/monitors/SLOs + 3 fault-injection scenarios |
| 8 | [AWS/EKS Deployment](Module-8-AWS-EKS-Deployment.md) | `make tf-apply-aws` | Cloud path, dedicated (not required for 1–7) |

## Sequencing

Modules 0–7 are meant to run in order on a local Kubernetes cluster. Module 8 is a parallel track:
run it instead of (or in addition to) the local path in Module 1 onward, using `-eks`/`-ecr`
target variants — see Module 8 for exactly which commands change.

## Source of Truth

This curriculum summarizes and re-sequences, but does not replace, the repo's own docs — when in
doubt, the repo wins:

- [`../INSTRUMENTATION.md`](../INSTRUMENTATION.md) — mechanism-level detail for every `make`
  stage (Modules 2–7)
- [`../USECASES.md`](../USECASES.md) — full facilitator script for the three diagnosis-lab
  scenarios (Module 7)
- [`../README.md`](../README.md) — architecture, credentials, AWS EKS reference (Module 8)
- [`../TROUBLESHOOTING.md`](../TROUBLESHOOTING.md) — layer-by-layer diagnostic model when
  something doesn't come up clean

## Superseded Content

This replaces the earlier product-pillar-organized curriculum (`Module-0..6` at the vault root,
one level up from this repo) — that older set is left untouched for now as a historical
reference, not deleted as part of this rewrite.

## PDF Booklet

A printable attendee booklet is built from these same modules — see
`partner-training-booklet.tex` in this folder (or the pre-built `.pdf` alongside it) for the
compiled version.
