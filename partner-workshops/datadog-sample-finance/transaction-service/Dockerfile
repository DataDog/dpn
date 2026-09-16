FROM node:20-alpine

# Create a non-root user — never run Finance services as root
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

# Copy manifests first so Docker layer-caches the install step
COPY package.json ./

# Production-only install — devDependencies (nodemon) are not needed in the image
RUN npm install --omit=dev

COPY src/ ./src/

# Drop privileges before starting the process
USER appuser

# ── DATADOG INSTRUMENTATION ──────────────────────────────────────────
# Step 3 — to enable APM via the dd-trace Node.js library:
#   1. Run: npm install dd-trace --save  (locally, then rebuild image)
#   2. Uncomment the --require flag below.
#   3. The tracer is initialised before any application code loads,
#      which is equivalent to placing require('dd-trace').init() as
#      the very first line of src/index.js — but does not require
#      modifying source code.
#
# CMD ["node", "--require", "dd-trace/init", "src/index.js"]
#
# Step 7 — Continuous Profiler is enabled via the tracer config
# (profiling: true in src/index.js) or via env var:
# ENV DD_PROFILING_ENABLED=true
#
# Docs: https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/nodejs/
# ─────────────────────────────────────────────────────────────────────

EXPOSE 8082

CMD ["node", "src/index.js"]
