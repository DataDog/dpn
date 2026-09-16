"use strict";

const stompit = require("stompit");
const pino = require("pino");
const tracer = require("dd-trace");

const logger = pino({
  level: process.env.LOG_LEVEL || "info",
  base: {
    service: process.env.DD_SERVICE || "transaction-service",
    env: process.env.DD_ENV || "development",
    version: process.env.DD_VERSION || "0.0.0",
    component: "messaging.producer",
  },
});

// ActiveMQ Artemis connection parameters.
// ACTIVEMQ_STOMP_URL format: stomp://host:61613 (set via app-config ConfigMap,
// matching the key used in deploy/kubernetes/base/01-config.yaml and the
// transaction-service Deployment env block).
const ACTIVEMQ_URL =
  process.env.ACTIVEMQ_STOMP_URL || "stomp://localhost:61613";
const [host, portStr] = ACTIVEMQ_URL.replace("stomp://", "").split(":");
const BROKER_PORT = parseInt(portStr || "61613", 10);

// ── DATADOG DATA STREAMS MONITORING (manual checkpoint) ───────────────
// dd-trace-js has NO built-in integration for the 'stompit' library (there
// is no automatic STOMP instrumentation in dd-trace-js at all), unlike
// account-service's JMS producer, which dd-trace-java instruments
// automatically. Setting DD_DATA_STREAMS_ENABLED=true alone does nothing
// here — the pathway checkpoint must be set manually, using dd-trace's
// low-level Data Streams API, and the resulting propagation headers
// merged into the STOMP frame headers before sending.
// Uncomment via 'make instrument' (Step 4 — Data Streams / Data Jobs
// Monitoring).
// Docs: https://docs.datadoghq.com/data_streams/

/**
 * Publishes a JSON payload to the given STOMP destination on ActiveMQ.
 *
 * @param {string} destination  Queue name, e.g. 'fraud.score.queue'
 * @param {object} payload      Serialisable object (no PII in values —
 *                              use IDs only; resolve PII in the consumer)
 * @returns {Promise<void>}
 */
function send(destination, payload) {
  return new Promise((resolve, reject) => {
    const connectOptions = {
      host: host || "localhost",
      port: BROKER_PORT,
      // stompit requires login/passcode/heart-beat nested under
      // connectHeaders (NOT top-level) — see node_modules/stompit/README.md.
      // Sending them top-level is silently ignored by the client, which
      // then connects with an empty username and Artemis rejects it with
      // "Security Error occurred: User name [null] or password is invalid".
      connectHeaders: {
        host: "/",
        login: process.env.ACTIVEMQ_USER || "guest",
        passcode: process.env.ACTIVEMQ_PASSWORD || "guest",
        // STOMP v1.2 — required by ActiveMQ Artemis
        "heart-beat": "0,0",
      },
    };

    stompit.connect(connectOptions, (connectErr, client) => {
      if (connectErr) {
        logger.error(
          {
            err: connectErr,
            destination,
            "messaging.destination": destination,
          },
          "jms.produce.connect_failed",
        );
        return reject(connectErr);
      }

      // Guard against uncaught 'error' events on the connection after
      // connect (e.g. broker-side protocol errors, idle disconnects raced
      // with our own client.disconnect() below). stompit's Client extends
      // EventEmitter — an unhandled 'error' event crashes the whole Node
      // process, which previously caused this service to crash-loop.
      client.on("error", (err) => {
        logger.error(
          {
            err,
            destination,
            "messaging.destination": destination,
          },
          "jms.produce.connection_error",
        );
      });

      const body = JSON.stringify(payload);

      // ── JMS / STOMP MESSAGE HEADERS ──────────────────────────────────
      // HIGH-CARDINALITY WARNING: messaging.message_id is unbounded.
      // Use it on spans and logs only — never as a DogStatsD metric tag.
      // Docs: https://docs.datadoghq.com/tagging/assigning_tags/
      //
      // jms.correlation_id carries the payment_id as a business-level
      // correlation key so the consumer can link its logs to the
      // originating payment without querying a database.
      // ─────────────────────────────────────────────────────────────────
      const headers = {
        destination: `/queue/${destination}`,
        "content-type": "application/json",
        "content-length": Buffer.byteLength(body),
        "jms-correlation-id": payload.payment_id || "",
      };

      // ── DATADOG DATA STREAMS MONITORING (manual checkpoint) ─────────
      // Uncomment via 'make instrument'. Writes pathway-propagation
      // headers directly into `headers` (the carrier) — must run before
      // client.send(headers) so the injected headers are actually sent.
      // No-ops on its own if DD_DATA_STREAMS_ENABLED isn't set, so this
      // is safe to leave uncommented once applied.
      // Docs: https://docs.datadoghq.com/data_streams/
      //
      // tracer.dataStreamsCheckpointer.setProduceCheckpoint(
      //   "jms",
      //   destination,
      //   headers,
      // );
      // ─────────────────────────────────────────────────────────────────

      const frame = client.send(headers);
      frame.write(body);
      frame.end();

      logger.info(
        {
          destination,
          payment_id: payload.payment_id,
          "messaging.destination": destination,
          "jms.correlation_id": payload.payment_id,
          // messaging.message_id is set by the broker after send —
          // log it from the consumer ACK if needed, not here.
        },
        "jms.produce",
      );

      client.disconnect();
      resolve();
    });
  });
}

module.exports = { send };
