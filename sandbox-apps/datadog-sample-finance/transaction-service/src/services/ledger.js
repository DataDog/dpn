"use strict";

const { Pool } = require("pg");
const pino = require("pino");

const logger = pino({
  level: process.env.LOG_LEVEL || "info",
  base: {
    service: process.env.DD_SERVICE || "transaction-service",
    env: process.env.DD_ENV || "development",
    version: process.env.DD_VERSION || "0.0.0",
    component: "ledger",
  },
});

// ── APM: ledger.commit span (always on) ──────────────────────────
// Custom span for ledger.commit.
// This wraps the database write so the APM flame graph shows ledger
// latency separately from fraud-queue publishing. Without this span,
// both operations are folded into the parent payment.authorize span
// and you cannot distinguish DB slowness from broker slowness.
//
const tracer = require("dd-trace");
// ─────────────────────────────────────────────────────────────────────

// ── PostgreSQL connection pool ────────────────────────────────────────
// A single pool is created lazily on first use and reused for the life of
// the process. Do NOT create a new Pool/Client per request — each one opens
// its own set of connections and background maintenance timers that are
// never reclaimed. That exact anti-pattern (a fresh client created per
// message, never closed) is what caused notification-service's memory leak
// and OOMKill — see the statsdClient fix in notification-service/main.go.
//
// POSTGRES_URL is shared with account-service and is JDBC-style
// ("jdbc:postgresql://host:port/db") since that's what Spring/JDBC expects.
// The `pg` driver wants a plain "postgresql://" URL instead, so strip the
// "jdbc:" prefix and inject credentials from POSTGRES_USER/POSTGRES_PASSWORD
// rather than introducing a second, Node-specific connection string.
let pool = null;

function getPool() {
  if (pool) return pool;

  // pg.Pool does NOT merge a credential-less connectionString with separate
  // user/password fields — the connectionString fully overrides them
  // (verified: passing both resulted in "no PostgreSQL user name specified
  // in startup packet", i.e. the user field was silently dropped).
  // Credentials must be embedded directly in the URL.
  const rawUrl =
    process.env.POSTGRES_URL || "jdbc:postgresql://postgres-ledger:5432/ledger";
  const withoutJdbcPrefix = rawUrl.replace(/^jdbc:/, "");
  const user = encodeURIComponent(process.env.POSTGRES_USER || "postgres");
  const password = encodeURIComponent(process.env.POSTGRES_PASSWORD || "");
  const withoutScheme = withoutJdbcPrefix.replace(/^postgresql:\/\//, "");
  const connectionString = `postgresql://${user}:${password}@${withoutScheme}`;

  pool = new Pool({
    connectionString,
    max: 10,
    idleTimeoutMillis: 30000,
  });

  pool.on("error", (err) => {
    // Emitted for errors on idle clients in the pool (e.g. connection
    // dropped). Logging here prevents an unhandled 'error' event from
    // crashing the whole process.
    logger.error(
      { err, "db.instance": "postgres-ledger" },
      "ledger.pool.error",
    );
  });

  return pool;
}

/**
 * Writes a payment record to the ledger and marks it settled.
 *
 * NOTE ON "settled": this sample app has no multi-day clearing workflow —
 * account-service and transaction-service both model instant, synchronous
 * payments. Rather than fabricate a fake asynchronous settlement pipeline,
 * transactions are inserted as 'pending' and then immediately updated to
 * 'settled' with settled_at = now(), representing same-day clearing for
 * demo purposes. In a real deployment, settled_at would instead be
 * populated asynchronously by a settlement/clearing integration.
 * batch-processor's ReconciliationJob reads exactly this status/settled_at
 * combination (see deploy/kubernetes/base/infrastructure/postgres-init.yaml).
 *
 * @param {object} params
 * @param {string} params.payment_id
 * @param {number} params.amount
 * @param {string} params.currency
 * @param {string} params.account_id
 * @returns {Promise<{committed: boolean}>}
 */
async function commit({ payment_id, amount, currency, account_id }) {
  // ── APM: open the ledger.commit child span ─────────────────────
  // Open a ledger.commit child span.
  // Tags:
  //   db.instance    → 'postgres-ledger' (matches DBM Agent config — enables
  //                    the "View in DBM" button on this span in APM)
  //   db.type        → 'postgresql'
  //   db.statement   → parameterised SQL only (never interpolate values —
  //                    prevents PII leakage into trace tags)
  //
  // Docs: https://docs.datadoghq.com/database_monitoring/connect_dbm_and_apm/
  //
  const span = tracer.startSpan("ledger.commit", {
    childOf: tracer.scope().active(),
    tags: {
      "db.instance": "postgres-ledger",
      "db.type": "postgresql",
      "db.statement":
        "INSERT INTO transactions (id, amount, currency, account_id, status) VALUES ($1,$2,$3,$4,$5)",
      "resource.name": "ledger.commit",
      "payment.currency": currency,
    },
  });
  // ─────────────────────────────────────────────────────────────────────

  try {
    const db = getPool();

    // ── WORKSHOP SCENARIO 1 (missing index on the ledger) ────────────
    // Payment-velocity check: look at the account's most recent activity
    // before writing the new payment, so we can flag unusually rapid
    // repeated payments. This read runs against idx_transactions_account_id
    // (deploy/kubernetes/base/infrastructure/postgres-init.yaml) and is fast
    // as long as that index exists. `make scenario-1` drops it, turning this
    // into a full table scan on the ledger — the slow db.query span the
    // workshop's APM/DBM investigation is built around. `make unscenario-1`
    // restores it.
    const velocitySpan = tracer.startSpan("ledger.velocity_check", {
      childOf: tracer.scope().active(),
      tags: {
        "db.instance": "postgres-ledger",
        "db.type": "postgresql",
        "db.statement":
          "SELECT id, amount, created_at FROM transactions WHERE account_id = $1 ORDER BY created_at DESC LIMIT 5",
        "resource.name": "ledger.velocity_check",
      },
    });
    try {
      const recentActivity = await db.query(
        `SELECT id, amount, created_at
           FROM transactions
          WHERE account_id = $1
          ORDER BY created_at DESC
          LIMIT 5`,
        [account_id],
      );
      if (recentActivity.rows.length >= 5) {
        logger.warn(
          { account_id, "db.instance": "postgres-ledger" },
          "ledger.velocity_check.high_activity",
        );
      }
    } finally {
      velocitySpan.finish();
    }

    await db.query(
      `INSERT INTO transactions (id, amount, currency, account_id, status)
       VALUES ($1, $2, $3, $4, 'pending')
       ON CONFLICT (id) DO NOTHING`,
      [payment_id, amount, currency, account_id],
    );

    // Simulate same-day settlement — see the "NOTE ON settled" doc comment
    // above for why this happens synchronously in this sample app.
    await db.query(
      `UPDATE transactions
          SET status = 'settled', settled_at = now()
        WHERE id = $1`,
      [payment_id],
    );

    logger.info(
      {
        payment_id,
        amount,
        currency,
        account_id,
        "db.instance": "postgres-ledger",
        "db.operation": "INSERT",
      },
      "ledger.commit",
    );

    span.finish();

    return { committed: true };
  } catch (err) {
    logger.error(
      { err, payment_id, "db.instance": "postgres-ledger" },
      "ledger.commit.failed",
    );

    // ── APM: mark span as error (Error Tracking) ───────────────────
    // Ledger error rate/count is derived from these error spans via a
    // span-based metric in deploy/terraform/datadog — no DogStatsD counter.
    const {
      ERROR_MESSAGE,
      ERROR_TYPE,
      ERROR_STACK,
    } = require("dd-trace/ext/tags");
    span.setTag(ERROR_TYPE, err.constructor.name);
    span.setTag(ERROR_MESSAGE, err.message);
    span.setTag(ERROR_STACK, err.stack);
    span.finish();
    // ─────────────────────────────────────────────────────────────────

    throw err;
  }
}

module.exports = { commit };
