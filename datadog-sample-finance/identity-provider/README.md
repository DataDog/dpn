# identity-provider — Keycloak (Open-Source IdP)

[Keycloak](https://www.keycloak.org/) is an open-source Identity and Access Management (IAM) solution backed by Red Hat and the CNCF ecosystem. It provides SAML 2.0 and OIDC support out of the box and mirrors the enterprise IdPs common in banking and insurance (Okta, Azure AD, PingFederate, IBM Security Verify).

This service adds:

- A pre-configured **`finance` realm** with five roles (`finance-analyst`, `finance-trader`, `finance-admin`, `finance-auditor`, `finance-compliance`) and five sample users
- An **OIDC client** (`finance-gateway`) so `gateway-api` can validate Bearer tokens and inject user identity into APM traces and logs
- A **SAML 2.0 client** (`datadog-saml`) pre-wired for Datadog Organization SSO — you supply the ACS URL for your Datadog site

---

## Quick Start

Keycloak starts automatically when you deploy the full stack:

```bash
make deploy-k8s
```

| Endpoint | URL | Credentials |
|---|---|---|
| **Admin console (primary)** | `https://localhost:30443/admin/master/console/#/finance` | `admin` / `Finance@Admin2025!` (dev default — `keycloak-admin-password` key in the `app-secrets` K8s Secret, not an `.env` var) |
| **Realm account page** | `https://localhost:30443/realms/finance/account/` | any finance realm user |

The primary URLs above go through the **nginx HTTPS proxy** (self-signed certificate, accept the browser warning
once) on NodePort `30443` — no extra setup required after `make deploy-k8s`. This matches the canonical access URL
documented in the root [`README.md`](../README.md#identity-provider).

The `localhost:8089` endpoints below are **not** exposed automatically — they require a manual port-forward, and
are intended for local `curl`/token-testing workflows (see [Part 2](#part-2--oidc-integration-with-gateway-api)),
not for primary browser access:

```bash
kubectl port-forward svc/keycloak 8089:8080 -n finance
```

| Endpoint (after port-forward) | URL | Credentials |
|---|---|---|
| Admin console | http://localhost:8089 | `admin` / `Finance@Admin2025!` (dev default — `keycloak-admin-password` key in the `app-secrets` K8s Secret) |
| Finance realm | http://localhost:8089/realms/finance | — |
| OIDC discovery | http://localhost:8089/realms/finance/.well-known/openid-configuration | — |
| SAML IdP metadata | http://localhost:8089/realms/finance/protocol/saml/descriptor | — |

The `finance` realm is imported automatically from `realm-export/finance-realm.json` on first start.

---

## Finance Realm

### Roles

| Role | Description |
|---|---|
| `finance-analyst` | Read-only: view accounts, balances, transaction history |
| `finance-trader` | Initiate payments and transfers; view own history |
| `finance-admin` | Full access: manage accounts, approve high-value transactions |
| `finance-auditor` | Compliance / read-only: full history for audit trail |
| `finance-compliance` | View accounts · approve or reject pending payments |

### Sample Users

| Username | Email | Role | Password |
|---|---|---|---|
| `alice.analyst` | alice.analyst@finance.local | `finance-analyst` | `Finance@2025!` |
| `bob.trader` | bob.trader@finance.local | `finance-trader` | `Finance@2025!` |
| `carol.admin` | carol.admin@finance.local | `finance-admin` | `Finance@2025!` |
| `dave.auditor` | dave.auditor@finance.local | `finance-auditor` | `Finance@2025!` |
| `eve.compliance` | eve.compliance@finance.local | `finance-compliance` | `Finance@2025!` |

> **Security note:** These passwords are for local development only. In any non-local environment, replace them via the Keycloak admin console or the `kcadm.sh` CLI before deployment.

---

## Part 1 — Datadog SSO (SAML 2.0)

Datadog supports SAML 2.0 for organisation-level SSO. Keycloak acts as the **Identity Provider (IdP)**; Datadog is the **Service Provider (SP)**.

Docs: https://docs.datadoghq.com/account_management/saml/

### Step-by-step configuration

#### Step A — Find your Datadog SAML endpoints

Log into Datadog and navigate to:
**Organization Settings > SAML**

Note the two values displayed on that page:

| Value | Example |
|---|---|
| **Assertion Consumer Service (ACS) URL** | `https://app.datadoghq.com/account/saml/assertion` |
| **Service Provider Entity ID** | `https://app.datadoghq.com` |

The ACS URL varies by site region:

| Datadog Site | ACS URL |
|---|---|
| US1 (default) | `https://app.datadoghq.com/account/saml/assertion` |
| EU | `https://app.datadoghq.eu/account/saml/assertion` |
| US3 | `https://us3.datadoghq.com/account/saml/assertion` |
| US5 | `https://us5.datadoghq.com/account/saml/assertion` |
| AP1 | `https://ap1.datadoghq.com/account/saml/assertion` |

#### Step B — Update the Keycloak SAML client

In the Keycloak admin console:

1. Go to **Clients > datadog-saml > Settings**
2. Set **Valid redirect URIs** to the ACS URL from Step A
3. Set **IDP Initiated SSO Relay State** (optional — use `https://app.datadoghq.com`)
4. Save

Alternatively, update `realm-export/finance-realm.json` before first import:

```json
"redirectUris": [
  "https://app.datadoghq.com/account/saml/assertion"
]
```

#### Step C — Export the Keycloak IdP metadata

Retrieve the Keycloak IdP metadata XML (requires `kubectl port-forward svc/keycloak 8089:8080 -n finance` first — see [Quick Start](#quick-start)):

```bash
curl -s http://localhost:8089/realms/finance/protocol/saml/descriptor -o keycloak-idp-metadata.xml
```

This XML contains the signing certificate and SSO endpoint that Datadog needs.

#### Step D — Upload the IdP metadata to Datadog

In Datadog **Organization Settings > SAML**:

1. Click **Upload Metadata File** and select `keycloak-idp-metadata.xml`
2. Datadog parses the certificate and SSO URL automatically
3. Click **Save Changes**

#### Step E — Test SSO login

1. In Datadog, click the **Test** button on the SAML settings page
2. Your browser redirects to the Keycloak login page for the `finance` realm
3. Log in as `carol.admin` (or any sample user)
4. Datadog receives the SAML assertion and creates a session

> **First-time user provisioning:** By default, Datadog creates a new user account on first SSO login using the email address from the SAML assertion. The user receives the default role configured in Organization Settings. You can override this with **SAML attribute-based role mapping** (see Step F).

#### Step F — Role mapping (optional but recommended)

Datadog can map SAML group attributes to Datadog roles, so that `finance-admin` in Keycloak automatically grants `Datadog Admin` in Datadog.

The `datadog-saml` client already includes a `roles` attribute mapper that sends Keycloak realm roles as:

```
Attribute name:  http://schemas.xmlsoap.org/claims/Group
Values:          finance-analyst  |  finance-trader  |  finance-admin  |  finance-auditor
```

In Datadog, configure the mapping under **Organization Settings > SAML > Attribute Statements**:

| Keycloak attribute | Datadog role |
|---|---|
| `http://schemas.xmlsoap.org/claims/Group` → `finance-admin` | Datadog Admin |
| `http://schemas.xmlsoap.org/claims/Group` → `finance-analyst` | Datadog Read Only |
| `http://schemas.xmlsoap.org/claims/Group` → `finance-auditor` | Datadog Read Only |
| `http://schemas.xmlsoap.org/claims/Group` → `finance-trader` | Datadog Standard |

Docs: https://docs.datadoghq.com/account_management/saml/mapping/

---

## Part 2 — OIDC Integration with gateway-api

The `finance-gateway` OIDC client allows `gateway-api` to validate Bearer tokens issued by Keycloak. This integration is **active by default** — the `verify_token` FastAPI dependency is already wired into all protected routes.

Only the **Datadog APM span tag injection** for user identity (`span.set_tag("user.id", ...)`) remains commented out, following the project's learning progression convention.

### Obtaining a token for testing

Requires `kubectl port-forward svc/keycloak 8089:8080 -n finance` first — see [Quick Start](#quick-start).

```bash
# Exchange username + password for an access token (Resource Owner Password grant)
TOKEN=$(curl -s -X POST \
  "http://localhost:8089/realms/finance/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=finance-gateway" \
  -d "client_secret=REPLACE_WITH_SECRET" \
  -d "username=bob.trader" \
  -d "password=Finance@2025!" \
  | jq -r .access_token)

# Call the gateway API with the Bearer token
curl -H "Authorization: Bearer $TOKEN" http://localhost:8080/v1/accounts/acc-001/balance
```

### What the OIDC integration provides

1. Every request to a protected route is validated against Keycloak's JWKS endpoint
2. The authenticated user's `sub` (UUID) and `roles` are extracted from the JWT
3. `user.id` and `user.roles` appear in every **structured log record** — enabling log-based user-activity analysis out of the box
4. Unauthenticated requests receive a `401 Unauthorized` before reaching business logic
5. When you enable APM (Step 3 of the Learning Progression), uncomment the `span.set_tag("user.id", user_sub)` lines in `gateway-api/main.py` to also surface user identity in Datadog APM traces

> **Finance observability value:** Correlating user identity with APM traces lets you answer "which user triggered this slow payment?" and "which trader's requests are generating the most fraud alerts?" directly from the Datadog APM UI.

---

## Security Notes

- **SAML signing:** The `datadog-saml` client is configured with `saml.server.signature: true` — Keycloak signs the SAML response. Datadog validates the signature using the certificate in the IdP metadata. Never disable this in production.
- **OIDC secrets:** The `finance-gateway` client secret is `REPLACE_WITH_SECRET` in the realm export. Rotate this before any non-local deployment via the Keycloak admin console and update `KEYCLOAK_CLIENT_SECRET` in your `.env` / secrets manager.
- **User passwords:** The sample user passwords in `finance-realm.json` are for local development only. Do not import this realm directly into a production Keycloak instance.
- **Network access:** Primary access already goes through the nginx HTTPS proxy (`https://localhost:30443`, self-signed cert). Only expose Keycloak beyond that over HTTPS as well — in Kubernetes, use an Ingress with TLS termination; in Terraform (AWS), use a load balancer with an ACM-managed certificate. The `localhost:8089` port-forward is for local `curl`/token-testing only and should never be exposed externally.
- **PII in traces:** When the OIDC middleware is enabled, `user.email` appears in APM span tags. If this constitutes PII under your data-handling policy, use `user.sub` (the opaque UUID subject) instead, and resolve the email only in your identity service.
  - Datadog `replace_tags` config: https://docs.datadoghq.com/tracing/configure_data_security/

---

## Key References

| Topic | URL |
|---|---|
| Datadog SAML SSO | https://docs.datadoghq.com/account_management/saml/ |
| SAML role mapping | https://docs.datadoghq.com/account_management/saml/mapping/ |
| Keycloak SAML 2.0 guide | https://www.keycloak.org/docs/latest/server_admin/#saml-clients |
| Keycloak OIDC guide | https://www.keycloak.org/docs/latest/server_admin/#_oidc_clients |
| Keycloak Docker | https://www.keycloak.org/server/containers |
| Datadog trace data security | https://docs.datadoghq.com/tracing/configure_data_security/ |
