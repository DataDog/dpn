"""
fraud-detection — main entry point
Connects to ActiveMQ Artemis via STOMP and listens on fraud.score.queue.
"""

import logging
import os
import time

# ── DATADOG INSTRUMENTATION ────────────────────────────────────────
# Uncomment to enable APM tracing for this service. Requires Single Step
# Instrumentation (Admission Controller library injection, enable via
# 'make instrument') plus the Datadog Operator installed in-cluster
# ('make deploy-k8s-dd') — this service intentionally has NO ddtrace pip
# dependency baked into the image; SSI injects it at pod startup, no
# rebuild required.
# Docs: https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/python/
#
# from ddtrace import patch_all
# ──────────────────────────────────────────────────────
# ── Datadog Log Injection (enable via 'make tags') ───────────────
# Uncomment to inject dd.trace_id / dd.span_id into every log record via
# ddtrace's logging integration — stitches JSON logs to APM traces so
# "View in APM" works from Log Management.
# Docs: https://docs.datadoghq.com/tracing/other_telemetry/connect_logs_and_traces/?tab=python
#
# from ddtrace.contrib.logging import patch as patch_logging
# ────────────────────────────────────────────────────
from pythonjsonlogger import jsonlogger

# ── DATADOG INSTRUMENTATION ────────────────────────────────────────
# Uncomment to activate ddtrace patching for all instrumented libraries.
# Must run once ddtrace is actually importable — see the SSI note above.
# Docs: https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/python/
#
# patch_all()
# ────────────────────────────────────────────────────
# ── Datadog Log Injection (enable via 'make tags') ───────────────
# patch_logging()
# ────────────────────────────────────────────────────

# ── DATADOG INSTRUMENTATION ────────────────────────────────────────
# Uncomment to enable Continuous Profiling for this service (see the SSI
# note above — same mechanism, no separate pip dependency).
# Docs: https://docs.datadoghq.com/profiler/enabling/python/
#
# import ddtrace.profiling.auto  # noqa: F401  — side-effect import, keep at top
# ────────────────────────────────────────────────────
import stomp
from listener import FraudScoreListener

# ── LOGGING SETUP ─────────────────────────────────────────────────────
# Structured JSON logging so that Datadog Log Management can parse
# every field without a custom pipeline processor.
# When ddtrace log injection is enabled (see block above), dd.trace_id
# and dd.span_id are automatically added to every log record.
# ─────────────────────────────────────────────────────────────────────
logger = logging.getLogger("fraud_detection")
logger.setLevel(logging.INFO)

_handler = logging.StreamHandler()
_formatter = jsonlogger.JsonFormatter(
    fmt="%(asctime)s %(levelname)s %(name)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
_handler.setFormatter(_formatter)
logger.addHandler(_handler)


def _broker_host() -> str:
    return os.environ.get("STOMP_HOST", "activemq-artemis")


def _broker_port() -> int:
    return int(os.environ.get("STOMP_PORT", "61613"))


def _queue() -> str:
    return os.environ.get("FRAUD_QUEUE", "fraud.score.queue")


def main() -> None:
    host = _broker_host()
    port = _broker_port()
    queue = _queue()

    logger.info(
        "Starting fraud-detection service",
        extra={
            "broker.host": host,
            "broker.port": port,
            "queue": queue,
            "service": os.environ.get("DD_SERVICE", "fraud-detection"),
            "env": os.environ.get("DD_ENV", "local"),
            "version": os.environ.get("DD_VERSION", "dev"),
        },
    )

    conn = None

    while True:
        try:
            # Recreate the connection each attempt so a dropped/half-open
            # transport (Artemis idle-connection TTL, AMQ229014) can't wedge
            # subsequent reconnects.
            conn = stomp.Connection(host_and_ports=[(host, port)])
            conn.set_listener("fraud_score_listener", FraudScoreListener(conn))
            conn.connect(
                username=os.environ.get("STOMP_USER", "admin"),
                passcode=os.environ.get("STOMP_PASS", "admin"),
                wait=True,
            )
            conn.subscribe(
                destination=f"/queue/{queue}",
                id=1,
                ack="client-individual",
            )
            logger.info("Subscribed to queue", extra={"queue": queue})

            # Block until disconnected, then loop to reconnect.
            while conn.is_connected():
                time.sleep(1)

            logger.warning("Broker connection lost — reconnecting in 5 s")
            time.sleep(5)

        except KeyboardInterrupt:
            logger.info("Shutting down fraud-detection service")
            if conn is not None and conn.is_connected():
                conn.disconnect()
            break

        except (
            stomp.exception.ConnectFailedException,
            stomp.exception.NotConnectedException,
        ):
            logger.warning(
                "Broker not connected — retrying in 5 s",
                extra={"broker.host": host, "broker.port": port},
            )
            time.sleep(5)

        except Exception as exc:
            # Any other broker/protocol error (e.g. a STOMP ERROR frame during
            # (re)connect) must not crash the process — log and retry so the
            # consumer survives Artemis idle-connection drops instead of exiting.
            logger.error(
                "Unexpected error in consumer loop — retrying in 5 s",
                extra={"error": str(exc), "error.type": type(exc).__name__},
            )
            time.sleep(5)


if __name__ == "__main__":
    main()
