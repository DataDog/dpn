# synthetics

Datadog Synthetic Monitoring test definitions for the Finance sample application.

| File | Type | Endpoint | Cadence |
|------|------|----------|---------|
| `health-check.yaml` | API (single-step) | `GET /health` | Every 60 s |
| `payment-flow.yaml` | API (multi-step) | `POST /v1/payments` + `GET /v1/payments/{id}` | Every 5 min |

---

## Synthetic → APM Trace Correlation

When Datadog runs a Synthetic test, the runner automatically injects three HTTP headers into every request:

| Header | Purpose |
|--------|---------|
| `x-datadog-trace-id` | Root trace ID for the entire test run |
| `x-datadog-parent-id` | Span ID of the Synthetic runner, becomes the parent of the gateway span |
| `x-datadog-origin: synthetics` | Marks the trace as originating from a Synthetic test |

The APM agent on `gateway-api` reads these headers and propagates them downstream — to `account-service`, `transaction-service`, `fraud-detection`, and `notification-service` — via standard B3/W3C/Datadog propagation headers. The result is a single distributed trace that spans all services, started by the Synthetic runner.

In the Synthetic test result page, click **View Trace** to jump directly to the APM waterfall for that specific test execution. Conversely, in APM > Traces, filter by `@synthetics.test_id` to see only traces triggered by Synthetic tests.

No code changes are required in the application for this correlation to work. The only requirement is that the APM agent is running and `DD_TRACE_PROPAGATION_STYLE` is set to a style that includes `datadog` (this is the default).

Docs: https://docs.datadoghq.com/synthetics/apm/

---

## Importing Tests

### Option 1 — Datadog UI

1. Go to UX Monitoring > Synthetic Tests.
2. Click **New Test** > **Import from File**.
3. Upload `health-check.yaml` or `payment-flow.yaml`.
4. Review the parsed configuration, then click **Save Test**.

### Option 2 — Terraform (`datadog_synthetics_test`)

The Terraform Datadog provider exposes a `datadog_synthetics_test` resource that maps directly to these YAML definitions. Store test definitions as Terraform variables or load them from the YAML files using `yamldecode(file(...))`.

```hcl
# deploy/terraform/aws/synthetics.tf

terraform {
  required_providers {
    datadog = {
      source  = "DataDog/datadog"
      version = "~> 3.0"
    }
  }
}

# ── Health Check ──────────────────────────────────────────────────────
resource "datadog_synthetics_test" "finance_health_check" {
  name    = "Finance Health Check — All Services"
  type    = "api"
  subtype = "http"
  status  = "live"

  request_definition {
    method = "GET"
    url    = "http://${var.gateway_host}:8080/health"
  }

  assertion {
    type     = "statusCode"
    operator = "is"
    target   = "200"
  }

  assertion {
    type     = "body"
    operator = "contains"
    target   = "ok"
  }

  assertion {
    type     = "responseTime"
    operator = "lessThan"
    target   = "2000"
  }

  locations = ["aws:eu-west-1"]

  options_list {
    tick_every = 60

    retry {
      count    = 1
      interval = 300
    }

    monitor_options {
      renotify_interval = 120
    }
  }

  tags = ["env:staging", "service:gateway-api", "team:finance"]
}

# ── Payment Flow (multi-step) ─────────────────────────────────────────
resource "datadog_synthetics_test" "finance_payment_flow" {
  name    = "Finance Payment Flow — Happy Path"
  type    = "api"
  subtype = "multi"
  status  = "live"

  # Step 1 — POST /v1/payments
  api_step {
    name    = "POST /v1/payments — Initiate payment"
    subtype = "http"

    request_definition {
      method = "POST"
      url    = "http://${var.gateway_host}:8080/v1/payments"
      body   = jsonencode({
        account_id       = "ACC-SYNTHETIC-001"
        amount           = 1.00
        currency         = "EUR"
        transaction_type = "payment"
      })
    }

    request_headers = {
      "Content-Type" = "application/json"
    }

    assertion {
      type     = "statusCode"
      operator = "is"
      target   = "200"
    }

    assertion {
      type      = "body"
      operator  = "validatesJSONPath"
      targetjsonpath {
        operator     = "isNotEmpty"
        jsonpath      = "$.payment_id"
      }
    }

    extracted_value {
      name  = "PAYMENT_ID"
      type  = "body"
      field = "$.payment_id"
    }
  }

  # Step 2 — GET /v1/payments/{payment_id}
  api_step {
    name    = "GET /v1/payments/{{ PAYMENT_ID }} — Verify payment record"
    subtype = "http"

    request_definition {
      method = "GET"
      url    = "http://${var.gateway_host}:8080/v1/payments/{{ PAYMENT_ID }}"
    }

    assertion {
      type     = "statusCode"
      operator = "is"
      target   = "200"
    }

    assertion {
      type      = "body"
      operator  = "validatesJSONPath"
      targetjsonpath {
        operator = "isNotEmpty"
        jsonpath  = "$.status"
      }
    }
  }

  locations = ["aws:eu-west-1"]

  options_list {
    tick_every = 300

    retry {
      count    = 1
      interval = 1000
    }
  }

  tags = ["env:staging", "service:gateway-api", "team:finance", "flow:payment"]
}
```

Terraform provider docs: https://registry.terraform.io/providers/DataDog/datadog/latest/docs/resources/synthetics_test

### Option 3 — datadog-ci CLI

```bash
# Install the CLI
npm install -g @datadog/datadog-ci

# Upload test definitions (creates or updates tests by name)
DD_API_KEY=$DD_API_KEY \
DD_APP_KEY=$DD_APP_KEY \
datadog-ci synthetics upload --files "synthetics/*.yaml"

# Run tests and block CI on failure
DD_API_KEY=$DD_API_KEY \
DD_APP_KEY=$DD_APP_KEY \
datadog-ci synthetics run-tests \
  --public-id <health-check-public-id> \
  --public-id <payment-flow-public-id> \
  --failOnCriticalErrors
```

Docs: https://docs.datadoghq.com/continuous_testing/cicd_integrations/

---

## CI/CD Integration Pattern

Recommended pipeline stages for the Finance app:

```
Build & push image
    → Unit tests
    → Integration tests
    → Deploy to staging
    → datadog-ci synthetics run-tests (health-check + payment-flow)
    → Deploy to production  ← blocked if Synthetic tests fail
```

The `datadog-ci` tool returns a non-zero exit code if any assertion fails or if the test times out, which naturally blocks the pipeline.

---

## Adding More Tests

| Endpoint | Recommended test type | Suggested assertions |
|----------|-----------------------|----------------------|
| `GET /v1/accounts/{id}/balance` | Single-step API | status 200, body contains `balance` field |
| `POST /v1/accounts` | Single-step API | status 201, Location header present |
| Full auth flow (login → payment → logout) | Multi-step API | Each step status, session cookie propagation |
| Fraud detection latency | Single-step API with timing assertion | `responseTime < 3000` on a high-value payment |

Docs: https://docs.datadoghq.com/synthetics/
