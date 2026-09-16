# Module 5 — Real User Monitoring (`make dem`)

## Overview

`make dem` turns on Digital Experience Monitoring — Browser RUM + Session Replay — for the
Finance dashboard (`frontend-stub/index.html`). Unlike every other stage, it doesn't apply a
patch: it creates the RUM application via a direct Datadog API call and injects the resulting
credentials with `sed`.

**Learning Objectives**
- Understand how `make dem` differs mechanically from the patch-based stages
- Enable Browser RUM + Session Replay and confirm a session is captured
- Apply PII masking correctly for a financial application's session replay

**Recommended Duration:** 30–45 minutes

**Prerequisites:** App running (Module 1). Independent of Modules 2–4 and Module 7 — RUM has no
Terraform dependency; Terraform no longer creates any RUM resource at all.

## Section 1 — What `make dem` Does

1. Resolves `DD_API_KEY`/`DD_APP_KEY` the same way `make create-dd-secret` and `make tf-apply-dd`
   do — `.env` locally, AWS Secrets Manager on EKS.
2. Checks for an existing RUM application named `finance-frontend` to avoid creating a duplicate.
3. Creates one if none exists, or reuses the existing one's `id`/`client_token`.
4. Caches both in the gitignored `.dem-state.json` so re-runs and `make undem` don't re-query.
5. Injects the credentials into `frontend-stub/index.html`'s `DD_RUM.init()` block via `sed`.

Idempotent via `.dem-applied` — a second run without `make undem` first is a no-op.

## Section 2 — Why It Matters

RUM captures real browser sessions for the Finance dashboard — page loads, clicks, errors —
and Session Replay lets you watch exactly what a user saw. This is the frontend counterpart to
Module 4's APM: APM only covers backend spans, RUM covers the browser side of the same user
journey.

## Section 3 — What Gets Enabled

| Feature | Config |
|---|---|
| Page view tracking | Automatic — all navigation events |
| User interactions | `trackUserInteractions: true` — clicks, form submits |
| Session Replay | `sessionReplaySampleRate: 100` — full replay recorded |
| PII masking | `defaultPrivacyLevel: 'mask-user-input'` — form values never recorded |
| Service | `finance-frontend` — appears in RUM > Applications |

**PII masking matters specifically here** — this is a financial dashboard. `mask-user-input`
ensures form values (account numbers, payment amounts typed into a form) are never captured in
Session Replay. Never disable this on a workload handling real financial data.

Finance-specific RUM actions the dashboard is already wired to emit (via `appLog()`, replaceable
with `DD_RUM.addAction()` once RUM is live):

| Action | Trigger | Tags to add |
|---|---|---|
| `payment.initiated` | `POST /v1/payments` success | `amount_bucket`, `currency` |
| `balance.checked` | `GET /v1/accounts/{id}/balance` | `account_tier` |
| `login.success` | Keycloak token issued | `role` |
| `payment.validated` | Compliance role approves/rejects | `decision` |

**Cardinality warning** — never pass raw `account_id`, `payment_id`, or exact amounts as RUM
action attributes. Bucket instead:
```javascript
amount_bucket: amount < 100 ? '<100' : amount < 1000 ? '100-1000' : '>1000'
```

## Section 4 — Workflow

```bash
make dem                # create/find the RUM app, inject credentials into frontend-stub/index.html
```

**Frontend RUM needs a special redeploy** — the dashboard HTML comes from the
`frontend-dashboard` ConfigMap, not the container image, so a plain rollout restart replays the
old HTML:

```bash
kubectl create configmap frontend-dashboard \
  --from-file=index.html=frontend-stub/index.html \
  -n finance --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment/frontend -n finance
```

**Reverse it:**
```bash
make undem              # deletes the RUM application via the API, restores frontend placeholders
```

## Validate

RUM → Applications → `finance-frontend` → Sessions → click any session → Session Replay
available.

## Practical Exercise

**Goal:** Enable RUM, generate a real session, and confirm PII masking works.

**Time:** 20–30 minutes

**Steps:**
1. `make dem`, then update and restart the frontend ConfigMap per Section 4.
2. Log into the Finance dashboard, click through a few actions (balance check, payment
   initiation if logged in as `bob.trader` or `carol.admin`).
3. Open the resulting session in RUM → Applications → `finance-frontend` → Sessions.
4. Confirm Session Replay shows the interaction but any form field is masked, not the literal
   value typed.
5. Reverse it with `make undem`.

**Expected outcome:** A captured RUM session with working Session Replay, and a confirmed PII
mask on at least one form field.

## Resources & Next Steps

- Browser RUM: https://docs.datadoghq.com/real_user_monitoring/browser/
- RUM Session Replay: https://docs.datadoghq.com/real_user_monitoring/session_replay/
- RUM Privacy / PII masking: https://docs.datadoghq.com/real_user_monitoring/session_replay/privacy_options/
- `sample/impl/INSTRUMENTATION.md` — `make dem` section, full API schema

**Next module**: [Module 6 — Security (`make security`)](Module-6-Security.md)
