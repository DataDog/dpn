"""
fraud-detection — STOMP message listener
Receives messages from fraud.score.queue, scores each transaction,
and logs a structured result record.
"""

import json
import logging
import os

import stomp

# ── DATADOG INSTRUMENTATION ────────────────────────────────────────
# Manual span around each fraud.score operation. Requires Single Step
# Instrumentation to have injected ddtrace (enable via 'make instrument'
# + 'make deploy-k8s-dd') — this service intentionally has no baked
# ddtrace pip dependency; 'tracer' is undefined without SSI having run.
# Docs: https://docs.datadoghq.com/tracing/trace_collection/custom_instrumentation/python/
#
# from ddtrace import tracer
# ─────────────────────────────────────────────────────────────────────
from scorer import score

# ── DATA STREAMS MONITORING (DSM) ────────────────────────────────────
# Optional follow-up: instrument this consumer for DSM pipeline visibility.
# DSM will track end-to-end latency from the JMS producer (account-service
# or transaction-service) through to this consumer, expose consumer lag,
# and surface the pathway in the Data Streams map.
# Requires: ddtrace[data_streams] installed + DD_DATA_STREAMS_ENABLED=true.
# Docs: https://docs.datadoghq.com/data_streams/python/
#
# from ddtrace.data_streams import set_consume_checkpoint
# ─────────────────────────────────────────────────────────────────────

# NOTE: no DogStatsD here. The finance.fraud.hits and finance.fraud.score
# metrics are generated from the fraud.score span below (span-based metrics
# in deploy/terraform/datadog), keyed off the fraud.score_bucket / fraud.score
# tags. Docs: https://docs.datadoghq.com/tracing/trace_pipeline/generate_metrics/

logger = logging.getLogger("fraud_detection.listener")


class FraudScoreListener(stomp.ConnectionListener):
    """
    STOMP ConnectionListener that handles messages on fraud.score.queue.

    Each message body is expected to be a JSON object with at least:
      {
        "transaction_id": "txn-8f3a2c",
        "amount":         1500.00,
        "currency":       "EUR",
        "transaction_type": "payment",
        "account_id":     "acc-001"
      }
    """

    def __init__(self, conn: stomp.Connection) -> None:
        # stomp.py's Frame object does NOT carry a reference back to the
        # connection (there is no frame.connection attribute in this
        # library version) — acking must go through the Connection object
        # itself. Without this, every on_message() call raised
        # AttributeError: 'Frame' object has no attribute 'connection',
        # which killed the STOMP receiver background thread on the very
        # first message and silently broke consumption (no more frames
        # were ever processed on that connection again).
        super().__init__()
        self.conn = conn

    def on_error(self, frame: stomp.utils.Frame) -> None:
        logger.error(
            "Received STOMP error frame",
            extra={"stomp.error": frame.body},
        )

    def on_message(self, frame: stomp.utils.Frame) -> None:
        """
        Main message handler. Called once per inbound STOMP frame.

        Processing order:
          1. DSM consume checkpoint (commented)   — records pipeline ingress timestamp
          2. Parse JSON body
          3. Call scorer.score()
          4. Custom APM span (commented)          — wraps scoring work
          5. DogStatsD gauge emit (commented)
          6. Structured log of the result
          7. ACK the frame so the broker removes it from the queue
        """
        subscription_id = frame.headers.get("subscription", "unknown")
        message_id = frame.headers.get("message-id", "unknown")
        correlation_id = frame.headers.get("correlation-id", "")

        # ── DATA STREAMS (DSM) — CONSUME CHECKPOINT (follow-up) ───────
        # Call this BEFORE processing so that DSM records the ingress
        # timestamp and can calculate producer-to-consumer latency.
        # The headers dict carries the DSM pathway context injected by
        # the Java producer (account-service / transaction-service).
        # Docs: https://docs.datadoghq.com/data_streams/python/
        #
        # set_consume_checkpoint("jms", "fraud.score.queue", frame.headers)
        # ─────────────────────────────────────────────────────────────

        try:
            body = json.loads(frame.body)
        except (json.JSONDecodeError, TypeError) as exc:
            logger.error(
                "Failed to parse message body",
                extra={
                    "message_id": message_id,
                    "error": str(exc),
                },
            )
            # ACK even on parse failure to avoid poison-pill infinite redelivery.
            self.conn.ack(message_id, subscription_id)
            return

        transaction_id = body.get("transaction_id", "unknown")
        transaction_type = body.get("transaction_type", "unknown")
        amount = float(body.get("amount", 0.0))
        currency = body.get("currency", "UNKNOWN")

        result = score({"transaction_id": transaction_id, "amount": amount})

        # ── DATADOG INSTRUMENTATION ────────────────────────────────────────
        # Wrap the scoring result in a manual span named "fraud.score" so it
        # shows up in the APM Trace view, taggable with Finance-domain
        # attributes for slice-and-dice analysis. Requires Single Step
        # Instrumentation to have injected ddtrace (see the import banner
        # near the top of this file) — 'tracer' is undefined otherwise.
        #
        # HIGH-CARDINALITY WARNING: do NOT add transaction_id or
        # message_id as span tags — those are unbounded.
        # Use correlation_id only if your broker reuses a bounded set.
        # Docs: https://docs.datadoghq.com/tracing/trace_collection/custom_instrumentation/python/
        #
        # with tracer.trace(
        #     "fraud.score", service="fraud-detection", resource=transaction_type
        # ) as span:
        #     span.set_tag("transaction.type", transaction_type)
        #     span.set_tag("payment.currency", currency)
        #     span.set_tag("fraud.score_bucket", result["bucket"])
        #     # Numeric score → feeds the finance.fraud.score distribution span metric.
        #     # Safe as a span metric value (aggregated), NOT used as a grouping tag.
        #     span.set_tag("fraud.score", float(result["score"]))
        #     span.set_tag("messaging.destination", "fraud.score.queue")
        #     # HIGH-CARDINALITY WARNING: messaging.message_id is per-message —
        #     # tag only when debugging a specific incident, not in production.
        #     # span.set_tag("messaging.message_id", message_id)
        #     if result["bucket"] == "high":
        #         span.error = 1
        #         span.set_tag("error.message", "High-risk transaction flagged")
        # ─────────────────────────────────────────────────────────────────────

        logger.info(
            "Fraud score computed",
            extra={
                # Business context
                "transaction_id": transaction_id,
                "transaction.type": transaction_type,
                "payment.currency": currency,
                "fraud.score": result["score"],
                "fraud.score_bucket": result["bucket"],
                # Messaging context
                "messaging.destination": "fraud.score.queue",
                "jms.correlation_id": correlation_id,
                # Omit message_id from logs in production to avoid
                # high-cardinality log index bloat.
            },
        )

        self.conn.ack(message_id, subscription_id)
