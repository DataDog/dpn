//
// ── DATADOG INSTRUMENTATION ────────────────────────────────────────
// Uncomment to enable APM tracing for this service.
// Requires: DD_ENV, DD_SERVICE, DD_VERSION, DD_AGENT_HOST env vars.
// Docs: https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/nodejs/
//
// const tracer = require("dd-trace").init({
//   service: process.env.DD_SERVICE || "transaction-service",
//   env: process.env.DD_ENV || "staging",
//   version: process.env.DD_VERSION || "0.0.0",
//   hostname: process.env.DD_AGENT_HOST || "datadog-agent",
//   // ── Datadog Log Injection (enable via 'make tags') ───────────────
//   // Uncomment to stitch pino JSON logs to APM traces via dd.trace_id /
//   // dd.span_id — enables "View in APM" from Log Management.
//   // Docs: https://docs.datadoghq.com/tracing/other_telemetry/connect_logs_and_traces/?tab=nodejs
//   //
//   // logInjection: true,
//   // ────────────────────────────────────────────────────────────
// });
// ─────────────────────────────────────────────────────────────────

("use strict");

const express = require("express");
const pino = require("pino");
const pinoHttp = require("pino-http");

const paymentsRouter = require("./routes/payments");

// ── STRUCTURED LOGGING ───────────────────────────────────────────────
// Always use structured JSON logs — raw console.log is never acceptable
// in production Finance services (no trace correlation, no log parsing).
// When dd-trace logInjection is enabled (Step 4), dd.trace_id and
// dd.span_id are automatically appended to every log record, enabling
// the "View in APM" button inside Datadog Log Management.
// ─────────────────────────────────────────────────────────────────────
const logger = pino({
  level: process.env.LOG_LEVEL || "info",
  // ── Datadog Unified Service Tagging (enable via 'make tags') ────────
  // Uncomment to stamp every JSON log line with service/env/version —
  // mirrors the DD_ENV/DD_SERVICE/DD_VERSION pod env vars uncommented in
  // the Kubernetes manifest by the same target.
  // Docs: https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging/
  //
  // base: {
  //   service: process.env.DD_SERVICE || "transaction-service",
  //   env: process.env.DD_ENV || "development",
  //   version: process.env.DD_VERSION || "0.0.0",
  // },
  // ─────────────────────────────────────────────────────────────────────
});

// ── Safety net for the fire-and-forget STOMP producer ──────────────────
// src/messaging/producer.js opens a fresh STOMP connection per message and
// intentionally treats JMS publish failures as best-effort (a payment must
// never be lost just because ActiveMQ is briefly unavailable). However the
// `stompit` client library can emit an async 'error' event on its internal
// frame stream (e.g. a broker-side protocol/auth hiccup on a racing
// connect/disconnect) that is NOT reachable via a normal try/catch or a
// listener on the client object. Left unhandled, this crashes the whole
// Node process. Catch it here so a transient broker error degrades to a
// logged warning instead of taking down the service.
process.on("uncaughtException", (err) => {
  logger.error(
    { err },
    "uncaughtException — continuing (see producer.js best-effort JMS publish)",
  );
});
process.on("unhandledRejection", (err) => {
  logger.error(
    { err },
    "unhandledRejection — continuing (see producer.js best-effort JMS publish)",
  );
});

const app = express();
const PORT = parseInt(process.env.PORT || "8082", 10);

// Parse JSON request bodies
app.use(express.json());

// HTTP request logging via pino-http (structured, not morgan)
app.use(pinoHttp({ logger }));

// ── HEALTH ENDPOINT ──────────────────────────────────────────────────
// Step 12 — target this endpoint with a Datadog Synthetic API test.
// Docs: https://docs.datadoghq.com/synthetics/
// ─────────────────────────────────────────────────────────────────────
app.get("/health", (_req, res) => {
  res.json({
    status: "ok",
    service: process.env.DD_SERVICE || "transaction-service",
    version: process.env.DD_VERSION || "0.0.0",
  });
});

// Mount the payments router under the versioned prefix
app.use("/v1/payments", paymentsRouter);

// Global error handler — always log with structured fields
app.use((err, req, res, _next) => {
  req.log.error(
    { err, route: req.path },
    "Unhandled error in transaction-service",
  );
  res.status(500).json({ error: "internal_server_error" });
});

app.listen(PORT, () => {
  logger.info({ port: PORT }, "transaction-service listening");
});

module.exports = app; // exported for testing
