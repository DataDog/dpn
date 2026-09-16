# Module 1 — Foundation & Deploy

## Overview

Before any Datadog signal is turned on, two things need to happen: the Datadog organization
itself needs to be configured (auth, users, keys), and the Meridian Financial app needs to be
running with **everything Datadog-related still off**. This module covers both — org setup is
general and applies to any customer; deploying the app "cold" is specific to this hands-on lab
and is the starting point every later module builds from.

**Learning Objectives**
- Configure a new Datadog org: authentication, users, teams, and API/App keys
- Understand when to use single vs. multi-org architecture
- Deploy Meridian Financial with zero Datadog instrumentation active, and confirm it runs cleanly
- Install the Datadog Agent without enabling any instrumentation layer yet

**Recommended Duration:** 1–1.5 hours

**Prerequisites**
- Datadog sandbox org with Admin access
- A local Kubernetes cluster (Docker Desktop, Rancher Desktop, kind, k3d, or minikube) **or** an
  AWS account — see Module 8 if going the AWS/EKS route
- `kubectl`, `helm`, `terraform` (`brew install kubectl helm terraform`)

## Section 1 — Organization Setup

### Single vs. multi-org

**Single org** is the default and right for most customers — one Datadog organization, all
users/data/config in one place.

**Multi-org** — a parent org with child accounts, each with its own OrgID and data isolation.
Common patterns:

| Pattern | When to use |
|---|---|
| MSP model | Parent org for the MSP, one child per end-customer account |
| Environment isolation | Separate orgs for prod vs. dev when compliance requires strict data separation |
| Business unit isolation | Separate billing/access per BU while keeping central visibility |

Docs: https://docs.datadoghq.com/account_management/multi_organization/

### Authentication — SAML/SSO

Required for any customer with a corporate IdP (Okta, Azure AD, PingFederate). Configure before
inviting users — migrating an existing user base is harder than starting with SSO in place.

| Question | If yes | If no |
|---|---|---|
| Does the customer have a corporate IdP? | Configure SAML | Username/password is fine |
| Is the customer an MSP? | Configure SAML on each child org | Single SAML config |
| Is password login a compliance risk? | Enable SAML Strict Mode | Leave Strict Mode off |

Docs: https://docs.datadoghq.com/account_management/saml/

### Users, Teams & Roles

| Role | Access | Use for |
|---|---|---|
| Admin | Full access — API keys, org settings, billing | Platform owners |
| Standard | Create dashboards/monitors/integrations, view everything | App teams, on-call |
| Read-Only | View only | Auditors, new joiners |

**Teams** route notifications — create them before creating any monitor. A monitor assigned to a
team with a Slack webhook configured on the team routes correctly with zero per-monitor config.

Docs: https://docs.datadoghq.com/account_management/teams/

### API & Application Keys

| Key type | Purpose | Who holds it |
|---|---|---|
| API key | Authenticates data sent to Datadog (Agent, Terraform) | The org — secrets manager |
| App key | Authenticates API calls made on a user's behalf | Each individual user |

Meridian Financial specifically needs both, sourced from `.env` locally or AWS Secrets Manager on
EKS:

```bash
cp .env.example .env
# set DD_API_KEY and DD_APP_KEY
```

> **Get the App Key *value*, not the Key ID** — the Application Keys page's list view shows the
> Key ID by default; click into the key to reveal the actual value. Using the Key ID causes `401
> Unauthorized` on every `terraform apply`.

Docs: https://docs.datadoghq.com/account_management/api-app-keys/

## Section 2 — Deploy Meridian Financial (cold, no Datadog)

The app runs cleanly with **zero** Datadog configuration — this is intentional, and worth
demonstrating before turning anything on.

```bash
make build            # build all 6 service images + traffic-generator
make deploy-k8s       # deploy the app into the finance namespace
```

> Non-Docker-Desktop clusters (kind/k3d/minikube/Colima) need an explicit image-load step — see
> the README's Redeploy & Teardown section for the exact command per tool.

**Confirm it's running:**
```bash
kubectl get pods -n finance                          # 12 pods Running
kubectl logs -n finance deploy/traffic-generator -f   # 200/201 responses, no 401 storms
```

Open the Finance dashboard at `http://localhost:30080`, log in as `carol.admin` /
`Finance@2025!` (see README's Credentials section for all 5 realm users and their roles). The
first login will fail with a `NetworkError` until you accept Keycloak's self-signed certificate at
`https://localhost:30443` once per browser profile.

At this point: no traces, no logs correlated to spans, no DBM, no RUM. That's the deliberate
starting state for every module that follows.

## Section 3 — Install the Datadog Agent

```bash
make deploy-k8s-dd   # installs the Datadog Operator (if absent), creates the secret, deploys the Agent
```

**Confirm it's running:**
```bash
kubectl get pods -n datadog                           # Agent DaemonSet + Cluster Agent Running
kubectl exec -n datadog daemonset/datadog-agent -c trace-agent -- agent status | grep "Traces received"
```

The Agent is now running, but every instrumentation layer still ships **commented out** in the
six services' manifests and the Agent config itself — nothing lights up in APM > Services yet.
That's Module 2 onward.

## Practical Exercise

**Goal:** Get Meridian Financial and the Datadog Agent both running, with zero instrumentation
active, and confirm the "before" state cleanly.

**Time:** 30–40 minutes

**Steps:**
1. Complete the org setup decisions (single/multi-org, SAML, teams/roles, API key plan) for your
   own sandbox — one sentence justification per decision.
2. `make build && make deploy-k8s` — confirm all 12 pods Running.
3. Log into the Finance dashboard as `carol.admin`.
4. `make deploy-k8s-dd` — confirm the Agent DaemonSet and Cluster Agent are Running.
5. Check APM > Services in Datadog — confirm nothing appears yet (this is expected and correct).

**Expected outcome:** A running Meridian Financial deployment, a running but "quiet" Datadog
Agent, and a documented org configuration — the clean baseline every later module instruments from.

## Resources & Next Steps

- Managing Multiple Organizations: https://docs.datadoghq.com/account_management/multi_organization/
- SAML SSO: https://docs.datadoghq.com/account_management/saml/
- Teams: https://docs.datadoghq.com/account_management/teams/
- API & Application Keys: https://docs.datadoghq.com/account_management/api-app-keys/
- `sample/impl/README.md` — full architecture, credentials, and Quick Start reference
- `sample/impl/TROUBLESHOOTING.md` — layer-by-layer diagnostic model if anything above doesn't
  come up clean

**Next module**: [Module 2 — Unified Service Tagging (`make tags`)](Module-2-Unified-Service-Tagging.md)
