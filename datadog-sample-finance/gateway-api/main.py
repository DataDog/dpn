"""
gateway-api — Public-facing REST API and authentication middleware.
Finance sample application | Datadog observability demo.

Run:
    uvicorn main:app --host 0.0.0.0 --port 8080 --reload

Authentication: Bearer token (JWT) issued by Keycloak — active by default.
All Datadog instrumentation is commented out. The app runs cleanly with
zero Datadog configuration. Follow the Learning Progression in README.md
to progressively enable each observability layer.
"""

import logging
import os
import time
import uuid

# ── DATADOG INSTRUMENTATION ────────────────────────────────────────
# Uncomment to enable Continuous Profiling for this service. Requires
# Single Step Instrumentation (Admission Controller library injection,
# enable via 'make instrument') plus the Datadog Operator installed
# in-cluster ('make deploy-k8s-dd') — this service intentionally has NO
# ddtrace pip dependency baked into the image; SSI injects it at pod
# startup, no rebuild required.
# Docs: https://docs.datadoghq.com/profiler/enabling/python/
#
# import ddtrace.profiling.auto  # noqa: F401  — side-effect import, starts profiler
# ─────────────────────────────────────────────────────────
import httpx

# ── DATADOG INSTRUMENTATION ────────────────────────────────────────
# Uncomment to enable APM tracing for this service. Requires Single Step
# Instrumentation (enable via 'make instrument') plus the Datadog
# Operator installed in-cluster ('make deploy-k8s-dd') — this service
# intentionally has NO ddtrace pip dependency baked into the image; SSI
# injects it at pod startup, no rebuild required.
# Docs: https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/python/
#
# from ddtrace import patch_all, tracer
# ─────────────────────────────────────────────────────────
# ── Datadog Log Injection (enable via 'make tags') ───────────────
# Uncomment to inject dd.trace_id / dd.span_id into every log record via
# ddtrace's logging integration — stitches JSON logs to APM traces so
# "View in APM" works from Log Management.
# Docs: https://docs.datadoghq.com/tracing/other_telemetry/connect_logs_and_traces/?tab=python
#
# from ddtrace.contrib.logging import patch as patch_logging
# ──────────────────────────────────────────────────────
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from jose import JWTError, jwt
from pydantic import BaseModel, Field
from pythonjsonlogger import jsonlogger

# ── DATADOG INSTRUMENTATION ────────────────────────────────────────
# Uncomment to activate ddtrace patching for all instrumented libraries.
# Must run once ddtrace is actually importable — see the SSI note above.
# Docs: https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/python/
#
# patch_all()  # must be called before importing instrumented libraries
# ──────────────────────────────────────────────────────
# ── Datadog Log Injection (enable via 'make tags') ───────────────
# patch_logging()  # injects dd.trace_id / dd.span_id into every log record
# ─────────────────────────────────────────────────────────────────────

# NOTE: custom metrics are NOT emitted via DogStatsD. They are generated from
# APM spans by span-based metrics defined in deploy/terraform/datadog (e.g.
# finance.payment.hits / finance.payment.duration). Keep the spans + tags below
# rich; the metrics follow automatically. Docs:
# https://docs.datadoghq.com/tracing/trace_pipeline/generate_metrics/


# ---------------------------------------------------------------------------
# Structured JSON logging
# ---------------------------------------------------------------------------
# Use python-json-logger so every log line is machine-parseable JSON.
# Datadog Log Management ingests this format without a custom pipeline.
# When Step 4 (DD_LOGS_INJECTION=true) is enabled, dd.trace_id and
# dd.span_id are automatically appended to every record by ddtrace.
#
# NOTE: this only covers loggers built via _build_logger() below (the app's
# own "gateway-api" logger). uvicorn's own "uvicorn"/"uvicorn.access" loggers
# are separate and, left unconfigured, print plain text with no `level` field
# -- Datadog's automatic status detection then misclassifies lines like
# "INFO:     Uvicorn running on ..." as status:error. See logging_config.json
# (passed to uvicorn via --log-config in the Dockerfile CMD) which routes
# those loggers through the same JSON formatter.


def _build_logger(name: str) -> logging.Logger:
    logger = logging.getLogger(name)
    handler = logging.StreamHandler()
    formatter = jsonlogger.JsonFormatter(
        fmt="%(asctime)s %(levelname)s %(name)s %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )
    handler.setFormatter(formatter)
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    logger.propagate = False
    return logger


log = _build_logger("gateway-api")


# ---------------------------------------------------------------------------
# App bootstrap
# ---------------------------------------------------------------------------

app = FastAPI(
    title="gateway-api",
    description="Finance sample app — public REST gateway",
    version=os.getenv("DD_VERSION", "1.0.0"),
)

ACCOUNT_SERVICE_URL = os.getenv("ACCOUNT_SERVICE_URL", "http://account-service:8081")
TRANSACTION_SERVICE_URL = os.getenv(
    "TRANSACTION_SERVICE_URL", "http://transaction-service:8082"
)

# ---------------------------------------------------------------------------
# Keycloak OIDC — JWT validation
# ---------------------------------------------------------------------------
# Endpoints are read from environment variables so the same image works in
# Docker Compose (keycloak:8080) and Kubernetes (ClusterIP service name).

KEYCLOAK_ISSUER = os.getenv("KEYCLOAK_ISSUER", "http://keycloak:8080/realms/finance")
KEYCLOAK_JWKS_URI = os.getenv(
    "KEYCLOAK_JWKS_URI",
    "http://keycloak:8080/realms/finance/protocol/openid-connect/certs",
)

_jwks_cache: dict | None = None  # in-memory cache; cleared on process restart
_jwks_cache_fetched_at: float = 0.0

# BUG FIX: this cache used to be populated once and kept FOREVER (only
# `if _jwks_cache is None`). If gateway-api started before Keycloak's realm
# was fully ready, the first fetch could succeed with an incomplete/about-
# to-rotate key set, or Keycloak could rotate its signing key later — either
# way every subsequent token would fail "Signature verification failed"
# forever, with no way to recover short of a manual pod restart. Fixed with
# two complementary mechanisms:
#   1. A TTL so the cache is refreshed periodically even if nothing goes
#      wrong (defends against silent key rotation).
#   2. Self-healing retry in verify_token(): on a signature/JWKS-related
#      failure, force a fresh fetch and retry once before returning 401.
#      This recovers immediately on the very next request instead of
#      waiting for the TTL to expire.
JWKS_CACHE_TTL_SECONDS = 300


async def _get_jwks(force_refresh: bool = False) -> dict:
    """Fetch Keycloak's public JWKS and cache in-memory, with a TTL."""
    global _jwks_cache, _jwks_cache_fetched_at
    is_stale = (time.time() - _jwks_cache_fetched_at) > JWKS_CACHE_TTL_SECONDS
    if force_refresh or _jwks_cache is None or is_stale:
        async with httpx.AsyncClient(timeout=5.0) as c:
            r = await c.get(KEYCLOAK_JWKS_URI)
            r.raise_for_status()
            _jwks_cache = r.json()
            _jwks_cache_fetched_at = time.time()
    return _jwks_cache


async def verify_token(request: Request) -> dict:
    """
    FastAPI dependency — validates the Bearer JWT from the Authorization header.

    Returns decoded token claims:
      - claims["sub"]    — opaque user subject UUID (safe as a span tag)
      - claims["email"]  — user email (PII — use sub in span tags instead)
      - claims["roles"]  — list of Keycloak realm roles

    Raises HTTP 401 if the token is missing, expired, or has an invalid signature.
    """
    auth_header = request.headers.get("Authorization", "")
    if not auth_header.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing Bearer token")
    token = auth_header[len("Bearer ") :]

    def _decode(jwks: dict) -> dict:
        return jwt.decode(
            token,
            jwks,
            algorithms=["RS256"],
            options={
                "verify_aud": False,
                # Issuer URL differs between host-side (localhost:8089) and
                # container-side (keycloak:8080) in Docker Compose — skip the
                # strict string comparison and validate the realm name instead.
                # In production, set KC_HOSTNAME on Keycloak to a stable external
                # URL and re-enable: options={"verify_aud": False}
                "verify_iss": False,
            },
        )

    try:
        try:
            claims = _decode(await _get_jwks())
        except JWTError as exc:
            # Self-healing retry: the cached JWKS may be stale (fetched before
            # Keycloak's realm was fully ready, or the signing key rotated
            # since). Force a fresh fetch and retry exactly once before
            # giving up — this is what lets the service recover on the very
            # next request instead of needing a manual restart.
            log.warning(
                "auth.jwks_stale_retry",
                extra={"error": str(exc)},
            )
            claims = _decode(await _get_jwks(force_refresh=True))

        # Manually verify the realm so tokens from other Keycloak realms are rejected.
        token_iss: str = claims.get("iss", "")
        if "/realms/finance" not in token_iss:
            raise JWTError(
                f"Token issuer does not belong to the 'finance' realm: {token_iss}"
            )
        return claims
    except JWTError as exc:
        log.warning("auth.token_invalid", extra={"error": str(exc)})
        raise HTTPException(status_code=401, detail="Invalid or expired token")


# Shared async HTTP client.
# keepalive_expiry=5 ensures stale connections to restarted containers are
# discarded quickly. retries=1 transparently reconnects on a dead connection
# (which can happen when a downstream container is recreated with a new IP).
http_client = httpx.AsyncClient(
    timeout=10.0,
    transport=httpx.AsyncHTTPTransport(retries=1),
    limits=httpx.Limits(
        max_keepalive_connections=10,
        max_connections=20,
        keepalive_expiry=5,  # seconds — short enough to survive container restarts
    ),
)


# ---------------------------------------------------------------------------
# Request / response models
# ---------------------------------------------------------------------------


class PaymentRequest(BaseModel):
    amount: float = Field(..., gt=0, description="Payment amount (must be positive)")
    currency: str = Field(
        ..., min_length=3, max_length=3, description="ISO 4217 currency code"
    )
    account_id: str = Field(..., description="Source account identifier")


class PaymentResponse(BaseModel):
    payment_id: str
    status: str
    amount: float
    currency: str
    account_id: str


class BalanceResponse(BaseModel):
    account_id: str
    balance: float
    currency: str


class DepositRequest(BaseModel):
    amount: float = Field(..., gt=0, description="Amount to credit to the account")
    note: str | None = Field(
        None, description="Optional description (e.g. 'Initial funding')"
    )


class DepositResponse(BaseModel):
    account_id: str
    deposited: float
    balance: float
    currency: str
    tier: str


class TransferRequest(BaseModel):
    from_account_id: str = Field(..., description="Source account ID")
    to_account_id: str = Field(..., description="Destination account ID")
    amount: float = Field(..., gt=0, description="Amount to transfer")
    currency: str = Field(
        ..., min_length=3, max_length=3, description="ISO 4217 currency code"
    )


class TransferResponse(BaseModel):
    transfer_id: str
    from_account_id: str
    to_account_id: str
    amount: float
    currency: str
    status: str
    created_at: str


class PaymentValidationRequest(BaseModel):
    action: str = Field(
        ...,
        pattern="^(approved|rejected|flagged)$",
        description="Validation decision: approved | rejected | flagged",
    )
    note: str | None = Field(None, description="Optional compliance note")


class PaymentDetail(BaseModel):
    payment_id: str
    status: str
    amount: float
    currency: str
    account_id: str
    created_at: str | None = None
    validated_at: str | None = None
    note: str | None = None


# ---------------------------------------------------------------------------
# Middleware — request logging
# ---------------------------------------------------------------------------


@app.middleware("http")
async def log_requests(request: Request, call_next):
    request_id = str(uuid.uuid4())
    start = time.perf_counter()

    log.info(
        "request.started",
        extra={
            "http.method": request.method,
            "http.route": request.url.path,
            "http.url": str(request.url),
            "request_id": request_id,
        },
    )

    response = await call_next(request)
    duration_ms = (time.perf_counter() - start) * 1000

    log.info(
        "request.finished",
        extra={
            "http.method": request.method,
            "http.route": request.url.path,
            "http.status_code": response.status_code,
            "duration_ms": round(duration_ms, 2),
            "request_id": request_id,
        },
    )
    return response


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@app.get("/health")
async def health():
    """Liveness probe — returns 200 when the service is ready."""
    return {"status": "ok", "service": "gateway-api"}


@app.get("/v1/payments", response_model=list[PaymentDetail])
async def list_payments(claims: dict = Depends(verify_token)):
    """
    List all payments.

    Accessible by any authenticated role. Used by the compliance dashboard
    to display pending payments awaiting validation.
    """
    user_sub = claims.get("sub", "unknown")
    log.info("payment.list", extra={"user.id": user_sub})
    try:
        resp = await http_client.get(f"{TRANSACTION_SERVICE_URL}/v1/payments")
        resp.raise_for_status()
        return resp.json()
    except httpx.HTTPError as exc:
        log.warning("transaction-service.unreachable", extra={"error": str(exc)})
        return []


@app.patch("/v1/payments/{payment_id}", response_model=PaymentDetail)
async def validate_payment(
    payment_id: str,
    body: PaymentValidationRequest,
    claims: dict = Depends(verify_token),
):
    """
    Approve, reject, or flag a payment.

    Requires finance-compliance or finance-admin role.
    Forwards the decision to transaction-service, which updates the payment status.
    """
    user_sub = claims.get("sub", "unknown")
    user_roles = claims.get("roles", [])

    VALIDATION_ROLES = {"finance-compliance", "finance-admin"}
    if not VALIDATION_ROLES.intersection(set(user_roles)):
        log.warning(
            "payment.validate.forbidden",
            extra={"user.id": user_sub, "user.roles": user_roles},
        )
        raise HTTPException(
            status_code=403,
            detail=f"Role '{', '.join(user_roles)}' cannot validate payments. "
            f"Requires finance-compliance or finance-admin.",
        )

    log.info(
        "payment.validate",
        extra={"payment_id": payment_id, "action": body.action, "user.id": user_sub},
    )

    try:
        resp = await http_client.patch(
            f"{TRANSACTION_SERVICE_URL}/v1/payments/{payment_id}",
            json={"status": body.action, "note": body.note},
        )
        resp.raise_for_status()
        payment_data = resp.json()
    except httpx.HTTPError as exc:
        log.error(
            "transaction-service.validate.failed",
            extra={"error": str(exc), "payment_id": payment_id},
        )
        raise HTTPException(
            status_code=502, detail="Could not reach transaction-service"
        )

    # On approval: debit the account balance.
    # Rejection and flagging leave the balance unchanged.
    if body.action == "approved":
        account_id = payment_data.get("account_id")
        amount = payment_data.get("amount", 0)
        if account_id:
            try:
                debit_resp = await http_client.patch(
                    f"{ACCOUNT_SERVICE_URL}/v1/accounts/{account_id}/balance",
                    json={"delta": -float(amount)},
                )
                debit_resp.raise_for_status()
                log.info(
                    "account.balance.debited",
                    extra={
                        "account_id": account_id,
                        "amount": amount,
                        "payment_id": payment_id,
                        "user.id": user_sub,
                    },
                )
            except httpx.HTTPError as exc:
                # Debit failure is logged but does NOT roll back the approval.
                # In production, this should trigger a reconciliation alert.
                log.error(
                    "account.balance.debit.failed",
                    extra={
                        "error": str(exc),
                        "payment_id": payment_id,
                        "account_id": account_id,
                    },
                )

    return payment_data


@app.post("/v1/accounts/{account_id}/deposit", response_model=DepositResponse)
async def deposit(
    account_id: str,
    body: DepositRequest,
    claims: dict = Depends(verify_token),
):
    """
    Credit an account (deposit / top-up).

    Restricted to finance-admin. Applies a positive delta to the account balance.
    """
    user_sub = claims.get("sub", "unknown")
    user_roles = claims.get("roles", [])

    if "finance-admin" not in user_roles:
        raise HTTPException(
            status_code=403,
            detail="Only finance-admin may deposit funds into an account.",
        )

    log.info(
        "account.deposit",
        extra={"account_id": account_id, "amount": body.amount, "user.id": user_sub},
    )

    try:
        resp = await http_client.patch(
            f"{ACCOUNT_SERVICE_URL}/v1/accounts/{account_id}/balance",
            json={"delta": body.amount},
        )
        resp.raise_for_status()
        data = resp.json()
    except httpx.HTTPError as exc:
        log.error(
            "account.deposit.failed",
            extra={"error": str(exc), "account_id": account_id},
        )
        raise HTTPException(status_code=502, detail="Could not reach account-service")

    return DepositResponse(
        account_id=data["accountId"],
        deposited=body.amount,
        balance=data["balance"],
        currency=data["currency"],
        tier=data["tier"],
    )


@app.post("/v1/transfers", response_model=TransferResponse, status_code=201)
async def transfer(
    body: TransferRequest,
    claims: dict = Depends(verify_token),
):
    """
    Transfer funds between two accounts.

    Requires finance-trader or finance-admin role.
    Atomically debits the source and credits the destination.
    If the credit fails the debit is reversed (best-effort rollback).
    """
    user_sub = claims.get("sub", "unknown")
    user_roles = claims.get("roles", [])

    TRANSFER_ROLES = {"finance-trader", "finance-admin"}
    if not TRANSFER_ROLES.intersection(set(user_roles)):
        raise HTTPException(
            status_code=403,
            detail=f"Role '{', '.join(user_roles)}' cannot transfer funds. "
            f"Requires finance-trader or finance-admin.",
        )

    if body.from_account_id == body.to_account_id:
        raise HTTPException(
            status_code=400, detail="Source and destination accounts must differ."
        )

    transfer_id = f"txf-{uuid.uuid4().hex[:12]}"
    created_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    log.info(
        "transfer.start",
        extra={
            "transfer_id": transfer_id,
            "from": body.from_account_id,
            "to": body.to_account_id,
            "amount": body.amount,
            "currency": body.currency,
            "user.id": user_sub,
        },
    )

    # Step 1 — debit source
    try:
        debit_resp = await http_client.patch(
            f"{ACCOUNT_SERVICE_URL}/v1/accounts/{body.from_account_id}/balance",
            json={"delta": -body.amount},
        )
        debit_resp.raise_for_status()
    except httpx.HTTPError as exc:
        log.error(
            "transfer.debit.failed",
            extra={"error": str(exc), "transfer_id": transfer_id},
        )
        raise HTTPException(status_code=502, detail="Could not debit source account")

    # Step 2 — credit destination
    try:
        credit_resp = await http_client.patch(
            f"{ACCOUNT_SERVICE_URL}/v1/accounts/{body.to_account_id}/balance",
            json={"delta": body.amount},
        )
        credit_resp.raise_for_status()
    except httpx.HTTPError as exc:
        log.error(
            "transfer.credit.failed",
            extra={"error": str(exc), "transfer_id": transfer_id},
        )
        # Best-effort reversal of the debit
        try:
            await http_client.patch(
                f"{ACCOUNT_SERVICE_URL}/v1/accounts/{body.from_account_id}/balance",
                json={"delta": body.amount},
            )
            log.info("transfer.debit.reversed", extra={"transfer_id": transfer_id})
        except httpx.HTTPError:
            log.error("transfer.reversal.failed", extra={"transfer_id": transfer_id})
        raise HTTPException(
            status_code=502, detail="Could not credit destination account"
        )

    log.info(
        "transfer.complete",
        extra={
            "transfer_id": transfer_id,
            "amount": body.amount,
            "currency": body.currency,
        },
    )
    return TransferResponse(
        transfer_id=transfer_id,
        from_account_id=body.from_account_id,
        to_account_id=body.to_account_id,
        amount=body.amount,
        currency=body.currency,
        status="completed",
        created_at=created_at,
    )


@app.post("/v1/payments", response_model=PaymentResponse, status_code=201)
async def initiate_payment(
    payload: PaymentRequest,
    request: Request,
    claims: dict = Depends(verify_token),
):
    """
    Initiate a payment.

    Validates the request, forwards to transaction-service for ledger write,
    and returns a payment_id for downstream tracking.
    Requires a valid Keycloak Bearer token.
    """
    user_sub = claims.get("sub", "unknown")  # opaque UUID — safe as a span tag
    user_roles = claims.get("roles", [])  # e.g. ["finance-trader"]
    # user_email = claims.get("email")          # PII — do not use as a span tag

    # Role enforcement: only finance-trader and finance-admin may initiate payments.
    # finance-analyst and finance-auditor are read-only roles.
    PAYMENT_ROLES = {"finance-trader", "finance-admin"}
    if not PAYMENT_ROLES.intersection(set(user_roles)):
        log.warning(
            "payment.authorize.forbidden",
            extra={"user.id": user_sub, "user.roles": user_roles},
        )
        raise HTTPException(
            status_code=403,
            detail=f"Role '{', '.join(user_roles)}' is read-only. "
            f"Requires finance-trader or finance-admin to initiate payments.",
        )

    payment_id = f"pay-{uuid.uuid4().hex[:12]}"
    start = time.perf_counter()

    log.info(
        "payment.authorize.start",
        extra={
            "payment_id": payment_id,
            "account_id": payload.account_id,
            "currency": payload.currency,
            # ── HIGH-CARDINALITY WARNING ────────────────────────────
            # Do NOT log raw amount values as tags — use bucketed ranges
            # for metrics. Log the exact value here (log volume is bounded)
            # but never emit it as a DogStatsD tag.
            # Docs: https://docs.datadoghq.com/tagging/assigning_tags/
            # ─────────────────────────────────────────────────────
            "amount": payload.amount,
            # ── SECURITY NOTE ─────────────────────────────────────────────
            # Never log card numbers, IBANs, SSNs, or raw account
            # balances in this log record. Log IDs only; resolve PII
            # in the service layer.
            # ─────────────────────────────────────────────
            "user.id": user_sub,
            "user.roles": user_roles,
        },
    )

    # ── DATADOG INSTRUMENTATION ──────────────────────────────────────
    # Step 5 — custom span for payment.authorize. Requires Single Step
    # Instrumentation to have injected ddtrace (see the import banners near
    # the top of this file) — 'tracer' is undefined otherwise.
    #
    # resource MUST be a bounded, normalised value. Using the raw account_id
    # here would create one APM resource per account (unbounded cardinality).
    # The account id is still captured as a span tag below for trace search.
    # Docs: https://docs.datadoghq.com/tracing/trace_collection/custom_instrumentation/python/
    #
    # with tracer.trace(
    #     "payment.authorize", service="gateway-api", resource="POST /v1/payments"
    # ) as span:
    #     span.set_tag("transaction.type", "payment")
    #     span.set_tag("payment.currency", payload.currency)
    #     span.set_tag("account.id", payload.account_id)  # bounded — safe as tag
    #     span.set_tag("user.id", user_sub)  # UUID from Keycloak — safe, not PII
    #     span.set_tag("user.roles", ",".join(user_roles))  # e.g. "finance-trader"
    # ──────────────────────────────────────────────────────────────────────

    # --- Stub: call transaction-service ---
    # In a real deployment this POST reaches the Node.js transaction-service.
    # We fall back to a stub response if the service is unreachable so the
    # gateway can be run standalone during local development.
    try:
        resp = await http_client.post(
            f"{TRANSACTION_SERVICE_URL}/v1/payments",
            json={
                "payment_id": payment_id,
                "amount": payload.amount,
                "currency": payload.currency,
                "account_id": payload.account_id,
            },
        )
        resp.raise_for_status()
        tx_status = resp.json().get("status", "pending")
    except httpx.HTTPError as exc:
        log.warning(
            "transaction-service.unreachable",
            extra={"error": str(exc), "payment_id": payment_id},
        )
        # Stub fallback — remove this branch when transaction-service is running.
        tx_status = "pending"

    # Notify: publish a payment-initiated alert via account-service so
    # notification-service (Go) can dispatch the email/SMS stub. This only
    # runs for callers who passed the finance-trader/finance-admin check
    # above. Best-effort — a notification hiccup must never fail the payment,
    # which has already been accepted by transaction-service.
    try:
        alert_resp = await http_client.post(
            f"{ACCOUNT_SERVICE_URL}/v1/accounts/{payload.account_id}/payment-alert",
            json={"currency": payload.currency},
        )
        if alert_resp.status_code == 404:
            log.warning(
                "payment.alert.account_not_found",
                extra={"payment_id": payment_id, "account_id": payload.account_id},
            )
    except httpx.HTTPError as exc:
        log.warning(
            "payment.alert.unreachable",
            extra={
                "error": str(exc),
                "payment_id": payment_id,
                "account_id": payload.account_id,
            },
        )

    elapsed_ms = (time.perf_counter() - start) * 1000

    log.info(
        "payment.authorize.complete",
        extra={
            "payment_id": payment_id,
            "status": tx_status,
            "duration_ms": round(elapsed_ms, 2),
            "currency": payload.currency,
        },
    )

    # (Custom metrics finance.payment.hits / finance.payment.duration are
    # generated from the payment.authorize span above via span-based metrics
    # in deploy/terraform/datadog — no DogStatsD emission here.)

    return PaymentResponse(
        payment_id=payment_id,
        status=tx_status,
        amount=payload.amount,
        currency=payload.currency,
        account_id=payload.account_id,
    )


@app.get("/v1/accounts/{account_id}/balance", response_model=BalanceResponse)
async def get_account_balance(
    account_id: str,
    claims: dict = Depends(verify_token),
):
    """
    Retrieve the current balance for an account.

    Proxies to account-service and returns balance with currency.
    Requires a valid Keycloak Bearer token.
    """
    user_sub = claims.get("sub", "unknown")
    user_roles = claims.get("roles", [])

    log.info(
        "account.balance_check.start",
        extra={"account_id": account_id, "user.id": user_sub, "user.roles": user_roles},
    )

    # ── DATADOG INSTRUMENTATION ──────────────────────────────────────
    # Step 5 — custom span for account.balance_check. Requires Single Step
    # Instrumentation to have injected ddtrace (see the import banners near
    # the top of this file) — 'tracer' is undefined otherwise.
    #
    # resource MUST be a bounded, normalised route — never the raw account_id
    # (that would create one APM resource per account). The account id remains
    # a span tag for trace search.
    # Docs: https://docs.datadoghq.com/tracing/trace_collection/custom_instrumentation/python/
    #
    # with tracer.trace(
    #     "account.balance_check",
    #     service="gateway-api",
    #     resource="GET /v1/accounts/{account_id}/balance",
    # ) as span:
    #     span.set_tag("account.id", account_id)
    #     span.set_tag("http.route", "/v1/accounts/{account_id}/balance")
    # ──────────────────────────────────────────────────────────────────────

    # --- Stub: call account-service ---
    try:
        resp = await http_client.get(
            f"{ACCOUNT_SERVICE_URL}/v1/accounts/{account_id}/balance"
        )
        resp.raise_for_status()
        data = resp.json()
        balance = data.get("balance", 0.0)
        currency = data.get("currency", "USD")
    except httpx.HTTPError as exc:
        log.warning(
            "account-service.unreachable",
            extra={"error": str(exc), "account_id": account_id},
        )
        # Stub fallback — remove when account-service is running.
        balance = 0.0
        currency = "USD"

    log.info(
        "account.balance_check.complete",
        extra={"account_id": account_id, "currency": currency},
    )

    return BalanceResponse(account_id=account_id, balance=balance, currency=currency)


# ---------------------------------------------------------------------------
# Startup / shutdown lifecycle
# ---------------------------------------------------------------------------


@app.on_event("startup")
async def on_startup():
    log.info(
        "gateway-api.started",
        extra={
            "version": os.getenv("DD_VERSION", "1.0.0"),
            "env": os.getenv("DD_ENV", "local"),
            "account_service_url": ACCOUNT_SERVICE_URL,
            "transaction_service_url": TRANSACTION_SERVICE_URL,
        },
    )


@app.on_event("shutdown")
async def on_shutdown():
    await http_client.aclose()
    log.info("gateway-api.stopped")
