FROM python:3.11-slim

# ── DATADOG INSTRUMENTATION ──────────────────────────────────────────
# Step 3 — Download the Datadog Java-agentless dd-java-agent is N/A here,
#           but for Python APM the dd-trace-py package (added to
#           requirements.txt) is sufficient. No separate binary is needed.
#
# Step 7 — Continuous Profiler: already bundled in ddtrace. Enable via
#           DD_PROFILING_ENABLED=true env var (set in docker-compose or K8s).
#
# If you want to inject ddtrace WITHOUT modifying CMD, you can prepend:
#   CMD ["ddtrace-run", "uvicorn", "main:app", ...]
# after uncommenting ddtrace in requirements.txt.
# Docs: https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/python/
# ─────────────────────────────────────────────────────────────────────

WORKDIR /app

# Install dependencies first (layer-cached unless requirements.txt changes).
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application source.
COPY main.py .
COPY logging_config.json .

# Non-root user for security best practice.
RUN adduser --disabled-password --gecos "" appuser
USER appuser

# Expose the application port (must match PORT in .env.example).
EXPOSE 8080

# ── DATADOG INSTRUMENTATION ──────────────────────────────────────────
# Step 3 — To enable APM via the ddtrace-run launcher (zero-code change),
#           replace the CMD below with the commented version.
#           ddtrace-run wraps the process and auto-patches all libraries.
# Docs: https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/python/
#
# CMD ["ddtrace-run", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
# ─────────────────────────────────────────────────────────────────────

# BUG FIX: without --log-config, uvicorn's own "uvicorn"/"uvicorn.access" loggers
# print plain text (e.g. "INFO:     Uvicorn running on ..."), which carries no
# `level` field for Datadog's status_remapper to read -- its automatic status
# detection then defaulted these lines to status:error on EVERY pod start,
# permanently polluting Log Management and the finance error-rate monitor.
# logging_config.json routes uvicorn's loggers through the same JSON formatter
# main.py already uses for the app's own "gateway-api" logger.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--log-config", "logging_config.json"]
