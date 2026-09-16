FROM python:3.11-slim

# ── BUILD ARGS ────────────────────────────────────────────────────────
# DD_VERSION is injected by CI so the image tag and the Datadog
# Deployment Tracking version are always in sync.
# Usage: docker build --build-arg DD_VERSION=$(git rev-parse --short HEAD) .
ARG DD_VERSION=dev
LABEL org.opencontainers.image.version="${DD_VERSION}"
LABEL com.datadoghq.service="fraud-detection"

WORKDIR /app

# Install dependencies first (layer-cache friendly).
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ── DATADOG JAVA AGENT — NOT APPLICABLE FOR PYTHON ───────────────────
# For Python, APM is injected via ddtrace-run or patch_all() in code.
# No separate agent binary is needed.
# If you prefer the admission-controller approach on Kubernetes, set:
#   admission.datadoghq.com/enabled: "true"
# on the pod spec and remove the ddtrace import from main.py.
# Docs: https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/python/
# ─────────────────────────────────────────────────────────────────────

COPY main.py listener.py scorer.py ./

# ── DATADOG ENTRYPOINT WRAPPER ────────────────────────────────────────
# When ddtrace is installed, you can replace `python main.py` with
# `ddtrace-run python main.py` to enable auto-instrumentation without
# any code change. Leave this commented until Step 3.
# Docs: https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/python/#getting-started
# ─────────────────────────────────────────────────────────────────────
CMD ["python", "main.py"]
# CMD ["ddtrace-run", "python", "main.py"]
