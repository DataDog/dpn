#!/usr/bin/env bash
# =============================================================================
# pin-dd-version.sh — stamp the real build version into manifests at deploy time
# =============================================================================
# Reads Kubernetes YAML on stdin, replaces the placeholder Unified Service
# Tagging version ("latest") with the actual build version ($DD_VERSION, the
# git short SHA), and writes the result to stdout.
#
# This ties every deployed pod's telemetry (traces, logs, metrics, profiles) to
# an exact commit so Datadog Deployment Tracking can correlate regressions and
# anomalies to a specific release — instead of everything showing up as the
# ambiguous "latest".
# Docs: https://docs.datadoghq.com/tracing/services/deployment_tracking/
#
# It rewrites exactly two fields (quote-agnostic, so it works on both raw source
# manifests and `kubectl kustomize` output, which renders values unquoted):
#   1. the  tags.datadoghq.com/version  pod label
#   2. the  DD_VERSION  env var value    (the only  value: latest  in these
#      manifests — verified; the image `:latest` tag and the `*-lib.version`
#      annotations use different keys/patterns and are intentionally untouched)
#
# Usage:
#   DD_VERSION=$(git rev-parse --short HEAD) ... | bash scripts/pin-dd-version.sh
#
# If DD_VERSION is unset it defaults to "dev" (never leaves a literal "latest").
# =============================================================================
set -euo pipefail

V="${DD_VERSION:-dev}"

sed -E \
  -e "s#(tags\.datadoghq\.com/version:)[[:space:]]*\"?latest\"?#\1 \"${V}\"#" \
  -e "s#(^[[:space:]]*value:)[[:space:]]*\"?latest\"?[[:space:]]*\$#\1 \"${V}\"#"
