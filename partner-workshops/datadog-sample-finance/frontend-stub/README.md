# frontend-stub

Minimal browser client simulating a Finance platform dashboard. It provides:

- A **payment form** (amount, currency, account ID, transaction type) that calls `POST /v1/payments`.
- An **account balance panel** that calls `GET /v1/accounts/{id}/balance`.
- Structured JSON console logging as a placeholder for Datadog RUM actions.

The page runs without any Datadog configuration. All RUM SDK code is commented out and labelled so a partner engineer can progressively enable each capability.

---

## Datadog Instrumentation Notes

### Learning Progression — Step 8 (RUM + Session Replay)

| Step | Action |
|------|--------|
| 8a | Run `make dem` — it creates the RUM application via a direct Datadog API call (not Terraform), and uncomments the `<script src="...datadog-rum.js">` tag and `DD_RUM.init({...})` block in `index.html`, injecting the real `applicationId`/`clientToken` automatically (no manual copy/paste) |
| 8c | Rebuild the frontend ConfigMap and `kubectl rollout restart deployment/frontend -n finance` so the updated `index.html` is served |
| 8d | Open the page and confirm the injected `applicationId`/`clientToken` values in `index.html` are real (not `REPLACE_WITH_APPLICATION_ID`/`REPLACE_WITH_CLIENT_TOKEN` placeholders) |
| 8e | Trigger a payment and verify the session appears in RUM > Sessions |
| 8f | Verify Session Replay recording appears for that session (`sessionReplaySampleRate: 100` is already set) |
| 8g | Replace `console.log` / `appLog()` calls with `DD_RUM.addAction(...)` calls (examples are inline) and verify the actions appear on the RUM session timeline |
| 8h | In APM > Traces, click a `gateway-api` trace and verify the RUM session link appears |

See `../INSTRUMENTATION.md` (Step 8) for the full `make dem` workflow, including the ConfigMap rebuild command and troubleshooting if credentials are left as placeholders.

Docs: https://docs.datadoghq.com/real_user_monitoring/browser/

---

## PII Masking

Financial applications handle sensitive data. The RUM SDK is pre-configured with `defaultPrivacyLevel: 'mask-user-input'`, which automatically redacts all form field values in Session Replay recordings. This prevents card numbers, IBANs, account balances, and other sensitive inputs from appearing in replay footage.

Additional masking guidance:

| Data type | Masking approach |
|-----------|-----------------|
| Form inputs (card number, IBAN, PIN) | Automatic via `defaultPrivacyLevel: 'mask-user-input'` |
| Displayed balance / account number | Add CSS class `dd-privacy-hidden` to the element |
| Raw amounts as RUM action attributes | Use `amount_bucket` (`<100`, `100-1000`, `>1000`) instead |
| Raw account IDs as RUM action attributes | Omit entirely — use `account_tier` instead |
| Raw transaction IDs | Omit from RUM attributes — high cardinality, not useful for analytics |

Reference: https://docs.datadoghq.com/real_user_monitoring/session_replay/privacy_options/

---

## Synthetic → RUM Correlation

When a Datadog Synthetic test runs against `/v1/payments`, the agent injects `x-datadog-trace-id` and `x-datadog-parent-id` HTTP headers automatically. The APM agent on `gateway-api` propagates these headers downstream, creating a linked trace. In the Synthetic test result, click **View Trace** to jump directly to the APM waterfall for that specific test execution.

No code changes are required in this page for that correlation to work — it is handled entirely at the APM agent and Synthetic runner layers.

---

## Running Locally

This is a static HTML file. Serve it from any HTTP server:

```bash
# Python
python3 -m http.server 3000 --directory frontend-stub/

# Node (npx)
npx serve frontend-stub/ -l 3000
```

The JS fetch calls expect the backend APIs to be reachable at the same origin, proxied via the **NGINX Kubernetes Service** (`deploy/kubernetes/base/services/frontend.yaml`), exposed on `http://localhost:30080` after `make deploy-k8s`. When serving this file standalone (outside the cluster), update the fetch URLs or configure a local reverse proxy to point at `http://localhost:30080`.
