# ── Build stage ───────────────────────────────────────────────────────────────
# Use the build platform (native) then cross-compile for the target platform.
# This avoids QEMU emulation for Go toolchain commands (go mod download, go build)
# which crash on ARM hosts building for amd64 due to QEMU lfstack issues.
FROM --platform=$BUILDPLATFORM golang:1.23-alpine AS builder

ARG TARGETOS=linux
ARG TARGETARCH=amd64

WORKDIR /app

# Install git for go mod download (some dependencies require it).
RUN apk add --no-cache git

COPY go.mod go.sum* ./
# go mod tidy resolves any new dependencies added by the instrumentation patch
# (e.g. dd-trace-go/v2). go.sum may not include them until tidy is run.
# GONOSUMCHECK=* prevents checksum failures when go.sum is stale or missing.
RUN GONOSUMCHECK=* GOFLAGS=-mod=mod go mod tidy && go mod download
COPY . .
RUN GONOSUMCHECK=* GOFLAGS=-mod=mod CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -trimpath -ldflags="-s -w" -o /notification-service .

# ── DATADOG INSTRUMENTATION — Orchestrion build (alternative to standard build) ──
# Replace the RUN go build step above with the block below to use Orchestrion
# for automatic compile-time APM instrumentation.
# Docs: https://docs.datadoghq.com/tracing/trace_collection/automatic_instrumentation/dd_libraries/go/
#
# RUN go install github.com/DataDog/orchestrion@latest && \
#     CGO_ENABLED=0 GOOS=linux orchestrion go build \
#         -trimpath -ldflags="-s -w" -o /notification-service .
# ──────────────────────────────────────────────────────────────────────────────

# ── Runtime stage ─────────────────────────────────────────────────────────────
FROM alpine:latest

# ca-certificates is required for TLS connections to external APIs (SMTP, SMS gateways).
RUN apk add --no-cache ca-certificates tzdata

WORKDIR /app

COPY --from=builder /notification-service /app/notification-service

# ── DATADOG INSTRUMENTATION — dd-java-agent equivalent note ──────────────────
# Go services do NOT require a separate agent JAR. APM is initialised in-process
# via tracer.Start() (manual) or via Orchestrion (compile-time automatic).
# The Datadog Agent sidecar/DaemonSet is still required for data ingestion.
# See: https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/go/
# ─────────────────────────────────────────────────────────────────────────────

# Non-root user for container security best practices.
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

# Environment defaults — override at runtime via docker-compose or K8s ConfigMap/Secret.
# DD_* variables are intentionally left unset here; supply them at deploy time.
ENV ACTIVEMQ_URL="stomp://activemq-artemis:61613"

EXPOSE 8083

CMD ["/app/notification-service"]
