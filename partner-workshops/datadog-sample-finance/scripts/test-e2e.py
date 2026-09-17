#!/usr/bin/env python3
"""
Finance Sample App — End-to-End Test Suite
==========================================
Covers every API operation and role-enforcement rule.
No external dependencies — Python stdlib only.

Prerequisites:
  The full Docker Compose stack must be running:
    make deploy-k8s
    # wait ~90 s for Keycloak to become healthy on first start

Run:
  python3 scripts/test-e2e.py        # from the project root (impl/)
  make test
"""

import json as _json

# ── Configuration ──────────────────────────────────────────────────────────────
# ── Service URLs ─────────────────────────────────────────────────────────────
# test-e2e.py is designed to run from a laptop with kubectl port-forward active.
# For always-on traffic, the in-cluster traffic-generator Deployment is preferred.
# Override URLs via env vars if needed:
#   GATEWAY_URL=http://... ACCOUNTS_URL=http://... python3 scripts/test-e2e.py
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE     = os.environ.get("FRONTEND_URL", "http://localhost:3000")   # nginx frontend proxy (port-forward)
GATEWAY  = os.environ.get("GATEWAY_URL",  "http://localhost:8080")   # gateway-api (port-forward)
ACCOUNTS = os.environ.get("ACCOUNTS_URL", "http://localhost:8081")   # account-service (port-forward)
TXNS     = os.environ.get("TXNS_URL",     "http://localhost:8082")   # transaction-service (port-forward)
KEYCLOAK = os.environ.get("KEYCLOAK_URL", "http://localhost:8089")   # Keycloak (port-forward)
REALM = "finance"
CLIENT_ID = "finance-gateway"
CLIENT_SECRET = "REPLACE_WITH_SECRET"
PASSWORD = "Finance@2025!"

# ── Counters ───────────────────────────────────────────────────────────────────
_passed = 0
_failed = 0
_section = ""


def section(title):
    global _section
    _section = title
    print(f"\n  {'─' * 60}")
    print(f"  {title}")
    print(f"  {'─' * 60}")


def chk(label, cond, detail=""):
    global _passed, _failed
    if cond:
        _passed += 1
        mark = "\033[92mPASS\033[0m"
    else:
        _failed += 1
        mark = "\033[91mFAIL\033[0m"
    suffix = f"  \033[90m{detail}\033[0m" if detail else ""
    print(f"  [{mark}] {label}{suffix}")
    return cond


# ── HTTP helpers ───────────────────────────────────────────────────────────────


def http(method, url, body=None, headers=None, timeout=8):
    """Make an HTTP request; returns (status_code, parsed_body)."""
    req_headers = {"Content-Type": "application/json"}
    if headers:
        req_headers.update(headers)
    data = _json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, headers=req_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            try:
                parsed = _json.loads(raw) if raw else {}
            except Exception:
                parsed = {}  # non-JSON response (e.g. HTML) — status is still valid
            return r.status, parsed
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            parsed = _json.loads(raw)
        except Exception:
            parsed = {}
        return e.code, parsed
    except Exception as exc:
        return 0, {"_error": str(exc)}


def token(username):
    """Obtain a Keycloak JWT for the given username (proxied via nginx)."""
    params = urllib.parse.urlencode(
        {
            "grant_type": "password",
            "client_id": CLIENT_ID,
            "client_secret": CLIENT_SECRET,
            "username": username,
            "password": PASSWORD,
        }
    ).encode()
    req = urllib.request.Request(
        f"{BASE}/auth/realms/{REALM}/protocol/openid-connect/token",
        data=params,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=8) as r:
        return _json.loads(r.read())["access_token"]


def auth(tok):
    return {"Authorization": f"Bearer {tok}", "Content-Type": "application/json"}


def balance(tok, account_id):
    status, body = http(
        "GET", f"{BASE}/v1/accounts/{account_id}/balance", headers=auth(tok)
    )
    if status == 200:
        return float(body.get("balance", 0))
    raise RuntimeError(f"balance check failed: HTTP {status} {body}")


def make_account(currency="EUR", tier="retail", initial_balance=10000):
    status, body = http(
        "POST",
        f"{BASE}/internal/accounts",
        body={
            "ownerId": "test-suite",
            "currency": currency,
            "tier": tier,
            "balance": initial_balance,
        },
    )
    if status == 201:
        return body["id"]
    raise RuntimeError(f"create account failed: HTTP {status} {body}")


# ── Pre-flight ─────────────────────────────────────────────────────────────────


def preflight():
    section("Pre-flight: service health")

    # Each service gets up to 3 attempts with a 5 s pause between them,
    # so 'make test' can be run immediately after restarting pods.
    services = [
        ("gateway-api  :8080", f"{GATEWAY}/health"),
        ("account-svc  :8081", f"{ACCOUNTS}/health"),
        ("transaction  :8082", f"{TXNS}/health"),
        ("nginx proxy  :3000", f"{BASE}/"),  # serves dashboard HTML
        (
            "keycloak     :8089",
            f"{KEYCLOAK}/realms/{REALM}/.well-known/openid-configuration",
        ),
    ]
    for name, url in services:
        status = 0
        for attempt in range(1, 4):  # up to 3 attempts
            status, _ = http("GET", url)
            if status == 200:
                break
            if attempt < 3:
                print(
                    f"  \033[90m  {name} not ready yet, retrying in 5 s (attempt {attempt}/3)...\033[0m"
                )
                time.sleep(5)
        ok = chk(f"{name} \u2192 {status}", status == 200)
        if not ok and ":8089" in name:
            print(
                "\n  \033[93mWarning:\033[0m Keycloak may still be starting (allow ~90 s on first run)."
            )
        if not ok:
            return False
    return True


# ── Authentication ─────────────────────────────────────────────────────────────

_tokens = {}


def auth_section():
    section("Authentication: all Keycloak users")
    users = [
        ("alice.analyst", "finance-analyst"),
        ("bob.trader", "finance-trader"),
        ("carol.admin", "finance-admin"),
        ("dave.auditor", "finance-auditor"),
        ("eve.compliance", "finance-compliance"),
    ]
    for username, expected_role in users:
        try:
            tok = token(username)
            _tokens[username] = tok
            chk(f"{username} ({expected_role})", bool(tok), "token issued")
        except Exception as exc:
            chk(f"{username} ({expected_role})", False, str(exc))


# ── Account operations ─────────────────────────────────────────────────────────


def account_section():
    section("Account operations")

    # Create
    status, body = http(
        "POST",
        f"{BASE}/internal/accounts",
        body={
            "ownerId": "suite",
            "currency": "EUR",
            "tier": "premium",
            "balance": 5000,
        },
    )
    acc1 = body.get("id")
    chk(
        "Create account (EUR, premium, 5 000)",
        status == 201 and bool(acc1),
        f"id={acc1} balance={body.get('balance')} currency={body.get('currency')}",
    )

    # List — account appears with correct balance
    status, lst = http("GET", f"{BASE}/internal/accounts")
    found = next(
        (a for a in (lst if isinstance(lst, list) else []) if a.get("id") == acc1), None
    )
    chk(
        "List accounts — new account visible with balance",
        status == 200 and found and float(found.get("balance", 0)) == 5000.0,
        f"{len(lst) if isinstance(lst, list) else '?'} total, balance={found and found.get('balance')}",
    )

    # Balance via gateway (JWT required)
    status, body = http(
        "GET", f"{BASE}/v1/accounts/{acc1}/balance", headers=auth(_tokens["bob.trader"])
    )
    chk(
        "Balance via gateway = 5 000",
        status == 200 and float(body.get("balance", 0)) == 5000.0,
        str(body),
    )

    return acc1


# ── Deposit ────────────────────────────────────────────────────────────────────


def deposit_section(acc_id):
    section("Deposit (finance-admin only)")

    # Admin can deposit
    status, body = http(
        "POST",
        f"{BASE}/v1/accounts/{acc_id}/deposit",
        body={"amount": 3000, "note": "Test top-up"},
        headers=auth(_tokens["carol.admin"]),
    )
    chk(
        "Admin deposits 3 000 → balance 8 000",
        status == 200 and float(body.get("balance", 0)) == 8000.0,
        f"balance={body.get('balance')} currency={body.get('currency')}",
    )

    # Trader cannot deposit → 403
    status, _ = http(
        "POST",
        f"{BASE}/v1/accounts/{acc_id}/deposit",
        body={"amount": 1},
        headers=auth(_tokens["bob.trader"]),
    )
    chk("Trader blocked from deposit → 403", status == 403, f"HTTP {status}")

    # Compliance cannot deposit → 403
    status, _ = http(
        "POST",
        f"{BASE}/v1/accounts/{acc_id}/deposit",
        body={"amount": 1},
        headers=auth(_tokens["eve.compliance"]),
    )
    chk("Compliance blocked from deposit → 403", status == 403, f"HTTP {status}")

    return 8000.0


# ── Transfer ───────────────────────────────────────────────────────────────────


def transfer_section():
    section("Transfer (finance-trader + finance-admin)")

    acc_src = make_account("EUR", "premium", 10000)
    acc_dst = make_account("EUR", "retail", 2000)

    # Trader transfers 4 000
    status, body = http(
        "POST",
        f"{BASE}/v1/transfers",
        body={
            "from_account_id": acc_src,
            "to_account_id": acc_dst,
            "amount": 4000,
            "currency": "EUR",
        },
        headers=auth(_tokens["bob.trader"]),
    )
    chk(
        "Trader transfers 4 000 src→dst",
        status == 201 and body.get("status") == "completed",
        f"id={body.get('transfer_id')}",
    )

    bal_src = balance(_tokens["carol.admin"], acc_src)
    bal_dst = balance(_tokens["carol.admin"], acc_dst)
    chk(f"src = 10 000 − 4 000 = 6 000", bal_src == 6000.0, f"{bal_src}")
    chk(f"dst = 2 000 + 4 000 = 6 000", bal_dst == 6000.0, f"{bal_dst}")

    # Admin transfers back 1 000
    status, body = http(
        "POST",
        f"{BASE}/v1/transfers",
        body={
            "from_account_id": acc_dst,
            "to_account_id": acc_src,
            "amount": 1000,
            "currency": "EUR",
        },
        headers=auth(_tokens["carol.admin"]),
    )
    chk(
        "Admin transfers 1 000 back dst→src",
        status == 201 and body.get("status") == "completed",
    )

    # Same-account transfer → 400
    status, _ = http(
        "POST",
        f"{BASE}/v1/transfers",
        body={
            "from_account_id": acc_src,
            "to_account_id": acc_src,
            "amount": 1,
            "currency": "EUR",
        },
        headers=auth(_tokens["bob.trader"]),
    )
    chk("Same-account transfer → 400", status == 400, f"HTTP {status}")

    # Compliance cannot transfer → 403
    status, _ = http(
        "POST",
        f"{BASE}/v1/transfers",
        body={
            "from_account_id": acc_src,
            "to_account_id": acc_dst,
            "amount": 1,
            "currency": "EUR",
        },
        headers=auth(_tokens["eve.compliance"]),
    )
    chk("Compliance blocked from transfer → 403", status == 403, f"HTTP {status}")

    # Analyst cannot transfer → 403
    status, _ = http(
        "POST",
        f"{BASE}/v1/transfers",
        body={
            "from_account_id": acc_src,
            "to_account_id": acc_dst,
            "amount": 1,
            "currency": "EUR",
        },
        headers=auth(_tokens["alice.analyst"]),
    )
    chk("Analyst blocked from transfer → 403", status == 403, f"HTTP {status}")


# ── Payment initiation ─────────────────────────────────────────────────────────


def payment_section():
    section("Payment initiation (finance-trader + finance-admin)")

    acc = make_account("EUR", "retail", 20000)

    # Unauthenticated → 401
    status, _ = http(
        "POST",
        f"{BASE}/v1/payments",
        body={"account_id": acc, "amount": 100, "currency": "EUR"},
    )
    chk("No token → 401", status == 401, f"HTTP {status}")

    # Analyst cannot initiate → 403
    status, _ = http(
        "POST",
        f"{BASE}/v1/payments",
        body={"account_id": acc, "amount": 100, "currency": "EUR"},
        headers=auth(_tokens["alice.analyst"]),
    )
    chk("Analyst blocked → 403", status == 403, f"HTTP {status}")

    # Auditor cannot initiate → 403
    status, _ = http(
        "POST",
        f"{BASE}/v1/payments",
        body={"account_id": acc, "amount": 100, "currency": "EUR"},
        headers=auth(_tokens["dave.auditor"]),
    )
    chk("Auditor blocked → 403", status == 403, f"HTTP {status}")

    # Trader can initiate → 201 pending
    status, body = http(
        "POST",
        f"{BASE}/v1/payments",
        body={"account_id": acc, "amount": 2500, "currency": "EUR"},
        headers=auth(_tokens["bob.trader"]),
    )
    pid = body.get("payment_id")
    chk(
        "Trader initiates → 201 pending",
        status == 201 and body.get("status") == "pending",
        f"id={pid}",
    )

    # Admin can also initiate → 201
    status, body = http(
        "POST",
        f"{BASE}/v1/payments",
        body={"account_id": acc, "amount": 500, "currency": "EUR"},
        headers=auth(_tokens["carol.admin"]),
    )
    chk(
        "Admin initiates → 201 pending",
        status == 201 and body.get("status") == "pending",
    )

    # List payments (any role can view)
    status, lst = http(
        "GET", f"{BASE}/v1/payments", headers=auth(_tokens["alice.analyst"])
    )
    found = next(
        (
            p
            for p in (lst if isinstance(lst, list) else [])
            if p.get("payment_id") == pid
        ),
        None,
    )
    chk(
        "Analyst can list payments (sees pending)",
        status == 200 and bool(found),
        f"{len(lst) if isinstance(lst, list) else '?'} total",
    )

    return acc, pid


# ── Payment validation + balance effect ────────────────────────────────────────


def validation_section(acc_id, payment_id):
    section("Payment validation (finance-compliance + finance-admin)")

    bal_before = balance(_tokens["carol.admin"], acc_id)

    # Trader cannot validate → 403
    status, _ = http(
        "PATCH",
        f"{BASE}/v1/payments/{payment_id}",
        body={"action": "approved"},
        headers=auth(_tokens["bob.trader"]),
    )
    chk("Trader blocked from validating → 403", status == 403, f"HTTP {status}")

    # Analyst cannot validate → 403
    status, _ = http(
        "PATCH",
        f"{BASE}/v1/payments/{payment_id}",
        body={"action": "approved"},
        headers=auth(_tokens["alice.analyst"]),
    )
    chk("Analyst blocked from validating → 403", status == 403, f"HTTP {status}")

    # Compliance approves → 2 500 EUR debited
    status, body = http(
        "PATCH",
        f"{BASE}/v1/payments/{payment_id}",
        body={"action": "approved", "note": "Looks good"},
        headers=auth(_tokens["eve.compliance"]),
    )
    chk(
        "Compliance approves → approved",
        status == 200 and body.get("status") == "approved",
        str(body.get("validated_at")),
    )

    bal_after = balance(_tokens["carol.admin"], acc_id)
    chk(
        f"Balance debited by 2 500 after approval",
        bal_after == bal_before - 2500,
        f"{bal_before} → {bal_after}",
    )

    # Create a second payment and reject it — balance unchanged
    status, pay2 = http(
        "POST",
        f"{BASE}/v1/payments",
        body={"account_id": acc_id, "amount": 1000, "currency": "EUR"},
        headers=auth(_tokens["bob.trader"]),
    )
    pid2 = pay2.get("payment_id")

    status, _ = http(
        "PATCH",
        f"{BASE}/v1/payments/{pid2}",
        body={"action": "rejected", "note": "Suspicious"},
        headers=auth(_tokens["eve.compliance"]),
    )
    chk("Compliance rejects second payment → rejected", status == 200)

    bal_after_reject = balance(_tokens["carol.admin"], acc_id)
    chk(
        "Balance unchanged after rejection",
        bal_after_reject == bal_after,
        f"{bal_after_reject}",
    )

    # Flag a third payment (admin)
    status, pay3 = http(
        "POST",
        f"{BASE}/v1/payments",
        body={"account_id": acc_id, "amount": 50000, "currency": "EUR"},
        headers=auth(_tokens["carol.admin"]),
    )
    pid3 = pay3.get("payment_id")
    status, body3 = http(
        "PATCH",
        f"{BASE}/v1/payments/{pid3}",
        body={"action": "flagged", "note": "Large transfer — review"},
        headers=auth(_tokens["carol.admin"]),
    )
    chk(
        "Admin flags large payment → flagged",
        status == 200 and body3.get("status") == "flagged",
    )

    # Invalid action → 400 or 422 (FastAPI emits 422 for Pydantic pattern mismatch)
    status, _ = http(
        "PATCH",
        f"{BASE}/v1/payments/{payment_id}",
        body={"action": "delete"},
        headers=auth(_tokens["eve.compliance"]),
    )
    chk("Invalid validation action → 4xx", status in (400, 422), f"HTTP {status}")


# ── Main ───────────────────────────────────────────────────────────────────────


def main():
    print(f"""
\033[1m╔══════════════════════════════════════════════════════════════════╗
║         Finance Sample App — End-to-End Test Suite              ║
╚══════════════════════════════════════════════════════════════════╝\033[0m

  Target: {BASE}  (nginx proxy → gateway-api / account-service)
""")

    # ── Pre-flight ──────────────────────────────────────────────────────
    if not preflight():
        print(
            "\n\033[91m✗ Pre-flight failed. Run 'make deploy-k8s' and start kubectl port-forward (or check the in-cluster traffic-generator: kubectl logs -n finance deploy/traffic-generator -f).\033[0m\n"
        )
        sys.exit(1)

    # ── Tests ────────────────────────────────────────────────────────────
    auth_section()
    if not all(u in _tokens for u in ["bob.trader", "carol.admin", "eve.compliance"]):
        print("\n\033[91m✗ Could not obtain required tokens. Aborting.\033[0m\n")
        sys.exit(1)

    acc1 = account_section()
    deposit_section(acc1)
    transfer_section()
    acc_pay, payment_id = payment_section()
    validation_section(acc_pay, payment_id)

    # ── Summary ──────────────────────────────────────────────────────────
    total = _passed + _failed
    print(f"\n  {'─' * 60}")
    if _failed == 0:
        print(f"  \033[92m✅  {_passed}/{total} tests passed.\033[0m")
    else:
        print(f"  \033[91m❌  {_failed}/{total} tests FAILED — see above.\033[0m")
    print()

    sys.exit(0 if _failed == 0 else 1)


if __name__ == "__main__":
    main()
