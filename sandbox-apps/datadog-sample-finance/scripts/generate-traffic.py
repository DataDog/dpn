#!/usr/bin/env python3
"""
Finance Sample App — Traffic Generator
========================================
Generates realistic mixed traffic against the Finance sample app running on K8s.
Uses only Python stdlib — no pip install required.

Usage:
  python3 scripts/generate-traffic.py                # run forever, ~1 req/s
  python3 scripts/generate-traffic.py --rate 3       # 3 req/s
  python3 scripts/generate-traffic.py --duration 120 # stop after 120 s
  python3 scripts/generate-traffic.py --once         # single pass, then exit

In-cluster (default when deployed as traffic-generator Deployment):
  Services are reached via ClusterIP DNS — no NodePort or port-forward needed.

From laptop (optional):
  Requires kubectl port-forward or NodePort access. Override URLs via env vars:
    GATEWAY_URL=http://localhost:8080 python3 scripts/generate-traffic.py

Keycloak users (finance realm):
  alice.analyst  — finance-analyst  — read-only
  bob.trader     — finance-trader   — can initiate payments
  carol.admin    — finance-admin    — full access
  dave.auditor   — finance-auditor  — read-only / compliance
"""

import argparse
import json

# ── Configuration ─────────────────────────────────────────────────────────────
# ── Service URLs ─────────────────────────────────────────────────────────────
# When running as the in-cluster traffic-generator Deployment, these env vars
# are set by the pod spec to the ClusterIP service DNS names (gateway-api:8080 etc).
#
# When running from a laptop, override via env vars:
#   GATEWAY_URL=http://localhost:8080 python3 scripts/generate-traffic.py
import os
import random
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime

GATEWAY = os.environ.get("GATEWAY_URL", "http://gateway-api:8080")
ACCOUNTS = os.environ.get("ACCOUNTS_URL", "http://account-service:8081")
TXNS = os.environ.get("TXNS_URL", "http://transaction-service:8082")
BATCH = os.environ.get("BATCH_URL", "http://batch-processor:8083")
KEYCLOAK = os.environ.get("KEYCLOAK_URL", "http://keycloak:8080")
REALM = "finance"
CLIENT_ID = "finance-gateway"
# Must match the `secret` field of the `finance-gateway` client in
# identity-provider/realm-export/finance-realm.json, which is seeded from
# the `keycloak-client-secret` key of the `app-secrets` K8s Secret.
CLIENT_SECRET = os.environ.get("KEYCLOAK_CLIENT_SECRET", "REPLACE_WITH_SECRET")

KEYCLOAK_USERS = [
    {"username": "alice.analyst", "password": "Finance@2025!", "role": "analyst"},
    {"username": "bob.trader", "password": "Finance@2025!", "role": "trader"},
    {"username": "carol.admin", "password": "Finance@2025!", "role": "admin"},
    {"username": "dave.auditor", "password": "Finance@2025!", "role": "auditor"},
]

CURRENCIES = ["EUR", "USD", "GBP", "JPY", "CHF"]
TIERS = ["retail", "premium", "corporate"]
AMOUNTS = [10.0, 25.5, 100.0, 250.0, 999.99, 5000.0, 12500.0]

# ── ANSI colours ──────────────────────────────────────────────────────────────

GREEN = "\033[92m"
YELLOW = "\033[93m"
RED = "\033[91m"
CYAN = "\033[96m"
GREY = "\033[90m"
BOLD = "\033[1m"
RESET = "\033[0m"

# ── Helpers ───────────────────────────────────────────────────────────────────


def ts():
    return datetime.now().strftime("%H:%M:%S")


def log(colour, method, url, status, detail=""):
    status_str = f"{colour}{status}{RESET}"
    detail_str = f"  {GREY}{detail}{RESET}" if detail else ""
    print(
        f"  {GREY}{ts()}{RESET}  {BOLD}{method:<6}{RESET} {url:<55} {status_str}{detail_str}"
    )


def http(method, url, body=None, headers=None, expected=(200, 201)):
    req_headers = {"Content-Type": "application/json"}
    if headers:
        req_headers.update(headers)
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, headers=req_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            resp_body = (
                json.loads(r.read())
                if r.headers.get("Content-Type", "").startswith("application/json")
                else {}
            )
            colour = GREEN if r.status in expected else YELLOW
            log(colour, method, url, r.status)
            return r.status, resp_body
    except urllib.error.HTTPError as e:
        colour = YELLOW if e.code in (401, 404) else RED
        log(colour, method, url, e.code)
        return e.code, {}
    except Exception as exc:
        log(RED, method, url, "ERR", str(exc)[:60])
        return 0, {}


# ── Token management ──────────────────────────────────────────────────────────

_tokens = {}  # username → {"token": str, "expires_at": float}


def get_token(user):
    """Return a valid JWT for the given user, refreshing if within 60 s of expiry."""
    entry = _tokens.get(user["username"])
    if entry and time.time() < entry["expires_at"] - 60:
        return entry["token"]

    params = urllib.parse.urlencode(
        {
            "grant_type": "password",
            "client_id": CLIENT_ID,
            "client_secret": CLIENT_SECRET,
            "username": user["username"],
            "password": user["password"],
        }
    ).encode()
    url = f"{KEYCLOAK}/realms/{REALM}/protocol/openid-connect/token"
    req = urllib.request.Request(
        url, data=params, headers={"Content-Type": "application/x-www-form-urlencoded"}
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            td = json.loads(r.read())
            token = td["access_token"]
            _tokens[user["username"]] = {
                "token": token,
                "expires_at": time.time() + td.get("expires_in", 300),
            }
            print(
                f"  {GREY}{ts()}{RESET}  {CYAN}TOKEN{RESET}  "
                f"{user['username']:<30} {GREEN}issued{RESET}  "
                f"{GREY}role={user['role']} expires_in={td.get('expires_in')}s{RESET}"
            )
            return token
    except Exception as exc:
        print(f"  {RED}[token error] {user['username']}: {exc}{RESET}")
        return None


def auth_header(user):
    token = get_token(user)
    return {"Authorization": f"Bearer {token}"} if token else {}


# ── Seed data ─────────────────────────────────────────────────────────────────

_account_ids = []

# account-service currently keeps accounts in an in-memory ConcurrentHashMap
# (see AccountService.java — "When PostgreSQL is wired up..."). That means
# every account-service pod restart/rollout wipes all previously seeded
# accounts. If this script only seeded once at startup and cached the IDs
# forever, every account-service restart would silently turn all
# balance-check/payment/payment-alert traffic into permanent 404s
# ("account_not_found") for the rest of this script's lifetime — including
# the payment-alert -> alert.queue JMS publish, which is best-effort and
# fails *silently* server-side, making it look like a broker/consumer bug
# rather than stale test data. Reseeding periodically keeps the account
# pool valid across account-service restarts without needing to manually
# restart the traffic generator too.
RESEED_INTERVAL_SECONDS = 120
_last_seed_time = 0.0


def seed_accounts():
    """Create a handful of accounts directly on account-service (no auth needed).

    Clears any previously cached IDs first so stale accounts (e.g. from
    before an account-service restart wiped its in-memory store) are
    dropped rather than accumulated forever.
    """
    global _last_seed_time
    _account_ids.clear()
    _last_seed_time = time.time()
    print(f"\n{BOLD}[seed] Creating test accounts on account-service…{RESET}")
    seeds = [
        {
            "ownerId": "owner-alice",
            "currency": "EUR",
            "tier": "premium",
            "balance": 50000.00,
        },
        {
            "ownerId": "owner-bob",
            "currency": "USD",
            "tier": "retail",
            "balance": 2500.00,
        },
        {
            "ownerId": "owner-carol",
            "currency": "GBP",
            "tier": "corporate",
            "balance": 250000.00,
        },
        {
            "ownerId": "owner-dave",
            "currency": "EUR",
            "tier": "retail",
            "balance": 1200.00,
        },
        {
            "ownerId": "owner-extra",
            "currency": "CHF",
            "tier": "premium",
            "balance": 18000.00,
        },
    ]
    for seed in seeds:
        status, body = http("POST", f"{ACCOUNTS}/v1/accounts", body=seed)
        if status == 201 and body.get("id"):
            _account_ids.append(body["id"])
    if _account_ids:
        print(
            f"  {GREEN}✓{RESET}  {len(_account_ids)} accounts created: {_account_ids}"
        )
    else:
        # Accounts may already exist from a previous run — try to list a few known IDs
        print(
            f"  {YELLOW}⚠{RESET}  Could not seed accounts — account-service may not persist data yet."
        )
        print(f"      Balance/payment calls will use stub responses from the gateway.")


# ── Traffic scenarios ─────────────────────────────────────────────────────────


def scenario_health_checks():
    """Hit /health on all three exposed services."""
    print(
        f"\n{BOLD}── health checks ─────────────────────────────────────────────────────{RESET}"
    )
    http("GET", f"{GATEWAY}/health")
    http("GET", f"{ACCOUNTS}/health")
    http("GET", f"{TXNS}/health")


def scenario_balance_check():
    """Authenticated balance check through the gateway (happy path)."""
    user = random.choice(KEYCLOAK_USERS)
    account_id = (
        random.choice(_account_ids)
        if _account_ids
        else f"acc-{random.randint(1, 5):03d}"
    )
    print(f"\n{BOLD}── balance check  [{user['role']}]{RESET}")
    http(
        "GET", f"{GATEWAY}/v1/accounts/{account_id}/balance", headers=auth_header(user)
    )


def scenario_payment():
    """Authenticated payment through the gateway."""
    # Traders and admins can initiate payments
    user = random.choice(
        [u for u in KEYCLOAK_USERS if u["role"] in ("trader", "admin")]
    )
    account_id = (
        random.choice(_account_ids)
        if _account_ids
        else f"acc-{random.randint(1, 5):03d}"
    )
    amount = random.choice(AMOUNTS)
    currency = random.choice(CURRENCIES)
    print(f"\n{BOLD}── payment  [{user['role']}]  {amount} {currency}{RESET}")
    status, body = http(
        "POST",
        f"{GATEWAY}/v1/payments",
        body={"amount": amount, "currency": currency, "account_id": account_id},
        headers=auth_header(user),
    )
    if status == 201 and body.get("payment_id"):
        # Follow up: fetch the payment from transaction-service
        pid = body["payment_id"]
        time.sleep(0.1)
        http("GET", f"{TXNS}/v1/payments/{pid}")


def scenario_account_lookup():
    """Direct account lookup on account-service (bypasses gateway — internal call pattern)."""
    account_id = (
        random.choice(_account_ids)
        if _account_ids
        else f"acc-{random.randint(1, 5):03d}"
    )
    print(f"\n{BOLD}── account lookup  (direct → account-service){RESET}")
    http("GET", f"{ACCOUNTS}/v1/accounts/{account_id}")
    http("GET", f"{ACCOUNTS}/v1/accounts/{account_id}/balance")


def scenario_unauthorized():
    """Call a protected gateway endpoint without a token — expects 401."""
    account_id = random.choice(_account_ids) if _account_ids else "acc-001"
    print(f"\n{BOLD}── unauthorised request  (no token){RESET}")
    http("GET", f"{GATEWAY}/v1/accounts/{account_id}/balance", expected=(401,))
    http(
        "POST",
        f"{GATEWAY}/v1/payments",
        body={"amount": 100.0, "currency": "EUR", "account_id": account_id},
        expected=(401,),
    )


def scenario_bad_payload():
    """Send a malformed payment — expects 422 (FastAPI validation error)."""
    user = random.choice(KEYCLOAK_USERS)
    print(f"\n{BOLD}── bad payload  [{user['role']}]{RESET}")
    # Missing currency
    http(
        "POST",
        f"{GATEWAY}/v1/payments",
        body={"amount": -5.0, "account_id": "acc-001"},
        headers=auth_header(user),
        expected=(422,),
    )


def scenario_not_found():
    """Look up a non-existent account — expects 404."""
    user = random.choice(KEYCLOAK_USERS)
    print(f"\n{BOLD}── not found{RESET}")
    http("GET", f"{ACCOUNTS}/v1/accounts/acc-does-not-exist-999")
    http("GET", f"{TXNS}/v1/payments/pay-does-not-exist-999")


def scenario_batch_job():
    """
    Trigger the end-of-day reconciliation batch job on-demand.

    In production this job only runs on a nightly cron (disabled by default
    in this sample). Triggering it here periodically — low weight, since
    each run reads/writes the ledger DB — produces a steady stream of
    batch.job / batch.step spans for Data Jobs Monitoring without waiting
    for midnight. See batch-processor's BatchJobController.
    """
    print(f"\n{BOLD}── batch job trigger  (reconciliation){RESET}")
    http("POST", f"{BATCH}/jobs/reconciliation", body={}, expected=(200, 201, 202))


# Weighted scenario table: (weight, callable)
SCENARIOS = [
    (30, scenario_balance_check),
    (25, scenario_payment),
    (20, scenario_account_lookup),
    (10, scenario_health_checks),
    (7, scenario_not_found),
    (5, scenario_unauthorized),
    (3, scenario_bad_payload),
    (2, scenario_batch_job),
]

_weights = [w for w, _ in SCENARIOS]
_functions = [f for _, f in SCENARIOS]


def pick_scenario():
    total = sum(_weights)
    r = random.uniform(0, total)
    running = 0
    for w, f in zip(_weights, _functions):
        running += w
        if r <= running:
            return f
    return _functions[-1]


# ── Stats tracker ─────────────────────────────────────────────────────────────


class Stats:
    def __init__(self):
        self.total = 0
        self.start = time.time()

    def tick(self):
        self.total += 1

    def summary(self):
        elapsed = time.time() - self.start
        rps = self.total / elapsed if elapsed > 0 else 0
        return f"{self.total} requests in {elapsed:.1f}s  ({rps:.2f} req/s)"


# ── Main ──────────────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(description="Finance stack traffic generator")
    parser.add_argument(
        "--rate",
        type=float,
        default=1.0,
        help="Target requests per second (default: 1)",
    )
    parser.add_argument(
        "--duration",
        type=float,
        default=0,
        help="Stop after N seconds (0 = run forever)",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="Run one pass through each scenario type and exit",
    )
    args = parser.parse_args()

    delay = 1.0 / max(args.rate, 0.1)

    print(f"""
{BOLD}╔══════════════════════════════════════════════════════════════════╗
║         Finance Sample App — Traffic Generator                   ║
╚══════════════════════════════════════════════════════════════════╝{RESET}

  Gateway API    → {CYAN}{GATEWAY}{RESET}
  Account Svc    → {CYAN}{ACCOUNTS}{RESET}
  Transaction Svc→ {CYAN}{TXNS}{RESET}
  Keycloak       → {CYAN}{KEYCLOAK}/realms/{REALM}{RESET}

  Rate           → {args.rate} req/s
  Duration       → {"forever" if not args.duration else f"{args.duration}s"}

  Press Ctrl-C to stop.
""")

    # ── Pre-flight: warm up tokens ────────────────────────────────────────────
    print(f"{BOLD}[init] Obtaining Keycloak tokens…{RESET}")
    for user in KEYCLOAK_USERS:
        get_token(user)

    # ── Seed test accounts ────────────────────────────────────────────────────
    seed_accounts()

    stats = Stats()
    deadline = time.time() + args.duration if args.duration else None

    if args.once:
        print(f"\n{BOLD}[once] Running one pass through each scenario…{RESET}")
        for _, fn in SCENARIOS:
            fn()
            stats.tick()
            time.sleep(0.3)
        print(f"\n{BOLD}Done.{RESET}  {stats.summary()}\n")
        return

    # ── Main loop ─────────────────────────────────────────────────────────────
    print(f"\n{BOLD}[loop] Starting traffic…{RESET}\n")
    try:
        while True:
            if deadline and time.time() >= deadline:
                break
            # Periodically refresh the seeded account pool. This is what makes
            # the generator resilient to account-service restarts (in-memory
            # store gets wiped) instead of hammering it with 404s forever —
            # see the comment above seed_accounts() for the full story.
            if time.time() - _last_seed_time >= RESEED_INTERVAL_SECONDS:
                seed_accounts()
            t0 = time.time()
            pick_scenario()()
            stats.tick()
            elapsed = time.time() - t0
            sleep_for = max(0, delay - elapsed)
            time.sleep(sleep_for)
    except KeyboardInterrupt:
        pass

    print(f"\n\n{BOLD}Summary:{RESET}  {stats.summary()}\n")


if __name__ == "__main__":
    main()
