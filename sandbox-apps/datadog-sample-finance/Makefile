# Meridian Financial — Datadog Observability Sample App
#
# DD_VERSION is auto-set to the git short SHA for Deployment Tracking.
# This ties every container image to an exact commit so that anomalies
# surfaced in Datadog APM, Profiler, or Data Jobs Monitoring can be
# linked back to a specific release via the Deployment Tracking UI.
# Docs: https://docs.datadoghq.com/tracing/deployment_tracking/
#
# Run 'make help' for the full list of targets with one-line descriptions.
# The end-to-end workflows below show the recommended target ordering.
#
# IMPORTANT — instrumentation is commented out by default: a fresh
# 'make deploy-k8s' + 'make deploy-k8s-dd' no longer enables Single Step
# Instrumentation (Admission Controller injection) or AppSec on any of the
# 6 service manifests, and no longer enables DBM / ASM / CWS / CSPM on the
# Datadog Agent — all of these ship commented out in the base manifests.
# Opt in explicitly: 'make instrument' (APM + Single Step + Profiler),
# 'make tags' (UST + log injection), 'make dbm' (Database Monitoring),
# 'make security' (ASM/CWS/CSPM), 'make dem' (Browser RUM). See
# INSTRUMENTATION.md for the full layer-by-layer breakdown.
#
# AWS + K8s workflow:
#   aws sso login --profile <profile>   # authenticate
#   make tf-plan-aws                    # review the plan first
#   make tf-apply-aws                   # provision EKS, ECR, VPC, IAM (~15-20 min)
#   export FE_URL=$$(cd deploy/terraform/aws && terraform output -raw frontend_keycloak_https_url)   # or frontend_keycloak_acm_url if domain_name is set
#   export DASH_URL=$$(cd deploy/terraform/aws && terraform output -raw frontend_url)
#   make tf-configure-kubectl           # configure kubectl
#   make build-ecr                      # build & push images for linux/amd64
#   make deploy-k8s-eks                 # deploy app (includes gp3 StorageClass) -- with FE_URL/DASH_URL
#                                        # exported above, Keycloak works on first boot, no restart needed
#   make deploy-k8s-dd                  # deploy Datadog Agent (auto-detects EKS)

.PHONY: all build build-ecr version test test-traffic deploy-k8s deploy-k8s-eks deploy-k8s-dd undeploy-k8s teardown instrument uninstrument tags untag dbm undbm security unsecurity dem undem create-dd-secret tf-plan-aws tf-apply-aws tf-configure-kubectl check-eks-kubeconfig frontend-url tf-destroy-aws sync-synthetics-config tf-plan-dd tf-apply-dd tf-destroy-dd scenario-1 unscenario-1 scenario-2 unscenario-2 scenario-3 unscenario-3 help

# Resolve DD_VERSION once so all targets share the same value.
# Falls back to 'dev' when git is not available (e.g. in a bare CI image).
DD_VERSION ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo 'dev')

# FE_URL/DASH_URL: optional, EKS-only. Export these (from 'terraform output',
# see the AWS + K8s workflow above) before 'make deploy-k8s-eks' so Keycloak's
# public URL and the finance-gateway client's allowed origins are correct on
# the very first deploy -- no post-deploy patch or pod restart needed. Never
# set locally: 'make deploy-k8s' always uses the checked-in localhost values.
FE_URL ?=
DASH_URL ?=

# ── Reusable canned recipes ───────────────────────────────────────────
# Expanded inline inside recipes with $(macro_name). Each keeps its own
# backslash continuations so it slots into a single recipe shell.

# Install/upgrade the Datadog Operator via Helm (idempotent).
define install_dd_operator
	helm repo add datadog https://helm.datadoghq.com 2>/dev/null || true; \
	helm repo update datadog 2>/dev/null; \
	helm upgrade --install datadog-operator datadog/datadog-operator \
		--namespace datadog --create-namespace \
		--set watchNamespaces="{datadog,finance}" \
		--set maximumGoroutines=800 \
		--wait --timeout 120s
endef

# Create the keycloak-tls Secret (self-signed) unless it already exists.
define ensure_keycloak_tls
	if ! kubectl get secret keycloak-tls -n finance >/dev/null 2>&1; then \
		openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
			-keyout /tmp/keycloak-tls.key \
			-out /tmp/keycloak-tls.crt \
			-subj "/CN=localhost/O=finance-sample-app" \
			-addext "subjectAltName=DNS:localhost,DNS:keycloak,IP:127.0.0.1" \
			2>/dev/null; \
		kubectl create secret tls keycloak-tls \
			--cert=/tmp/keycloak-tls.crt \
			--key=/tmp/keycloak-tls.key \
			-n finance; \
		rm -f /tmp/keycloak-tls.crt /tmp/keycloak-tls.key; \
		echo "  ✓ keycloak-tls Secret created"; \
	else \
		echo "  keycloak-tls Secret already exists — skipping"; \
	fi
endef

# Create the keycloak-realm-import ConfigMap from the realm export dir.
# On EKS, if FE_URL/DASH_URL are set (see deploy-k8s-eks), append the real
# Keycloak/dashboard origins to redirectUris/webOrigins in a templated copy
# so the finance-gateway client is correct from Keycloak's first boot --
# no live kcadm patch needed afterward. Local's checked-in localhost entries
# stay untouched either way (FE_URL/DASH_URL are never set for 'deploy-k8s').
define create_realm_cm
	if [ -n "$$FE_URL" ] && [ -n "$$DASH_URL" ]; then \
		rm -rf /tmp/finance-realm-import; \
		mkdir -p /tmp/finance-realm-import; \
		cp identity-provider/realm-export/*.json /tmp/finance-realm-import/; \
		sed -i.bak \
			-e "s|\"https://localhost:30443/\*\"|&,\n        \"$$FE_URL/*\"|" \
			-e "s|\"http://localhost:30080/\*\"|&,\n        \"$$DASH_URL/*\"|" \
			-e "s|\"https://localhost:30443\"|&,\n        \"$$FE_URL\"|" \
			-e "s|\"http://localhost:30080\"|&,\n        \"$$DASH_URL\"|" \
			/tmp/finance-realm-import/finance-realm.json; \
		rm -f /tmp/finance-realm-import/*.bak; \
		kubectl create configmap keycloak-realm-import \
			--from-file=/tmp/finance-realm-import/ \
			-n finance --dry-run=client -o yaml | kubectl apply -f -; \
		rm -rf /tmp/finance-realm-import; \
	else \
		kubectl create configmap keycloak-realm-import \
			--from-file=identity-provider/realm-export/ \
			-n finance --dry-run=client -o yaml | kubectl apply -f -; \
	fi
endef

# Create the traffic-generator-script ConfigMap.
define create_traffic_cm
	kubectl create configmap traffic-generator-script \
		--from-file=generate-traffic.py=scripts/generate-traffic.py \
		-n finance --dry-run=client -o yaml | kubectl apply -f -
endef

# Build the frontend-dashboard ConfigMap, injecting KEYCLOAK_PUBLIC_URL.
# Prefers the FE_URL env var (set for EKS, see deploy-k8s-eks) over the
# checked-in default so the dashboard stub is correct from the first deploy.
define create_frontend_cm
	KEYCLOAK_URL=$${FE_URL:-$$(grep 'KEYCLOAK_PUBLIC_URL' deploy/kubernetes/base/01-config.yaml | sed 's/.*: *"\(.*\)"/\1/')}; \
	sed "s|https://localhost:30443|$$KEYCLOAK_URL|g" frontend-stub/index.html > /tmp/finance-index.html; \
	kubectl create configmap frontend-dashboard \
		--from-file=index.html=/tmp/finance-index.html \
		-n finance --dry-run=client -o yaml | kubectl apply -f -; \
	rm -f /tmp/finance-index.html
endef

# Print the "redeploy to activate" hint shared by instrument/uninstrument.
# NOTE: 'kubectl rollout restart' alone recreates pods from whatever Deployment
# spec is ALREADY stored in the cluster — it does NOT re-read the local YAML,
# so it cannot pick up the DD_ENV/DD_SERVICE/DD_VERSION env vars, UST labels, or
# annotations these patches just uncommented. 'make deploy-k8s' (local) /
# 'make deploy-k8s-eks' (EKS) re-applies the manifests via 'kubectl apply',
# which both pushes the patched fields AND triggers the rollout — no separate
# rollout restart is needed after it.
define print_redeploy_hint
	echo "   Local: make build && load images into k3s && make deploy-k8s"; \
	echo "   EKS:   make build-ecr && make deploy-k8s-eks"
endef

# Resolve DD_API_KEY / DD_APP_KEY into $$API_KEY / $$APP_KEY / $$DD_KEY_SRC shell vars.
# Single source of truth: .env. Sets all three to "" if .env is missing, or either
# key is unset/empty/still the literal placeholder "REPLACE_ME" — callers are
# responsible for checking and failing with their own error message (kept out of
# this macro so 'create-dd-secret', 'tf-plan-dd'/'tf-apply-dd'/'tf-destroy-dd', 'dem',
# and 'undem' can each word their own error text). Deliberately a canned recipe (not
# a recipe-embedded '$(MAKE) <target>' call) so 'make -n dem'/'make -n undem'/etc.
# stay true dry-runs: a recipe line containing the literal text '$(MAKE)' is always
# executed by GNU Make even under -n, which would otherwise silently resolve and
# print real credentials during a dry run.
define resolve_dd_keys
	API_KEY=""; APP_KEY=""; DD_KEY_SRC=""; \
	if [ -f .env ]; then \
		API_KEY=$$(grep '^DD_API_KEY=' .env | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'"); \
		APP_KEY=$$(grep '^DD_APP_KEY=' .env | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'"); \
		if [ "$$API_KEY" = "REPLACE_ME" ]; then API_KEY=""; fi; \
		if [ "$$APP_KEY" = "REPLACE_ME" ]; then APP_KEY=""; fi; \
		if [ -n "$$API_KEY" ] && [ -n "$$APP_KEY" ]; then DD_KEY_SRC=".env"; fi; \
	fi
endef
# ──────────────────────────────────────────────────────────────────────


all: build

## help: [Misc] Show this help message (all available make targets with descriptions).
help:
	@echo "Meridian Financial - Datadog Observability Sample App"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@awk '/^## [a-zA-Z0-9_-]+:/ { \
			sub(/^## /, ""); \
			split($$0, a, ":"); \
			target=a[1]; \
			sub(/^[^:]*: */, ""); \
			desc=$$0; \
			cat="Misc"; \
			if (match(desc, /^\[[A-Za-z0-9 &\/]+\]/)) { \
				cat=substr(desc, RSTART+1, RLENGTH-2); \
				desc=substr(desc, RSTART+RLENGTH); \
				sub(/^ +/, "", desc); \
			} \
			lines[cat]=lines[cat] sprintf("  \033[36m%-24s\033[0m %s\n", target, desc); \
		} \
		END { \
			n=split("Misc,Build & Test,Local Kubernetes,AWS / Terraform,Datadog Instrumentation,Workshop Scenarios", order, ","); \
			for (i=1; i<=n; i++) { \
				c=order[i]; \
				if (lines[c] != "") { \
					printf "\033[1m%s\033[0m\n", c; \
					printf "%s", lines[c]; \
					printf "\n"; \
				} \
			} \
		}' $(MAKEFILE_LIST)

## version: [Misc] Print the DD_VERSION that will be embedded in image labels and env vars.
version:
	@echo "DD_VERSION=$(DD_VERSION)"

## instrument: [Datadog Instrumentation] Uncomment In-depth instrumentation — four narrated steps under one
##             sentinel: (1) the APM custom-span patches (transaction-service,
##             notification-service — unchanged), (2) Single Step Instrumentation
##             gating (admission.datadoghq.com/enabled label + <lang>-lib.version
##             annotation, all 6 services), (3) Continuous Profiler
##             (DD_PROFILING_ENABLED, 5 services — not notification-service, whose
##             profiler is already gated by step 1's Go patch), (4) Data Streams /
##             Data Jobs Monitoring (DD_DATA_STREAMS_ENABLED on account-service,
##             fraud-detection, notification-service, transaction-service;
##             DD_DATA_JOBS_ENABLED on batch-processor — gateway-api has neither,
##             it doesn't produce/consume JMS). Also prints a Service Catalog note
##             (service.datadog.yaml already ships for all 6 services — static,
##             nothing to patch). Applies unified diff patches — fully reversible
##             with make uninstrument. Idempotent: a second run is a clean no-op
##             (tracked via .instrumentation-applied). See INSTRUMENTATION.md for
##             what each patch enables. APM + Single Step + Profiler + DSM/DJM
##             only — for UST/log injection see 'make tags', for AppSec see
##             'make security', for Browser RUM see 'make dem'.
##
##             After patching, redeploy (rollout restart alone won't pick up the
##             new env vars/annotations — the manifests must be re-applied):
##               Local:  make build && load images into k3s && make deploy-k8s
##               EKS:    make build-ecr && make deploy-k8s-eks
##             fraud-detection's DSM extra is a baked pip dependency (not just an
##             env var) — it needs the same rebuild step above, a plain
##             kubectl apply is not enough even locally.
instrument:
	@if [ -f .instrumentation-applied ]; then \
		echo "Instrumentation already enabled. Run 'make uninstrument' first to reapply."; \
	else \
		echo "Step 1: Applying ddtrace/APM code patches (gateway-api, fraud-detection,"; \
		echo "  transaction-service, notification-service)..."; \
		for p in scripts/patches/*.patch; do \
			svc=$$(basename $$p .patch); \
			echo "  $$svc"; \
			patch -p1 --forward -s < $$p || true; \
		done; \
		echo ""; \
		echo "Step 2: Enabling Single Step Instrumentation (Admission Controller) gating..."; \
		echo "  Why: admission.datadoghq.com/enabled + the <lang>-lib.version annotation"; \
		echo "  are what opt each pod into tracer injection at startup. Uncommenting now"; \
		echo "  on all 6 service manifests:"; \
		for p in scripts/patches/instrument-sso/sso-*.patch; do \
			svc=$$(basename $$p .patch | sed 's/^sso-//'); \
			echo "    $$svc"; \
			patch -p1 --forward -s < $$p || true; \
		done; \
		echo ""; \
		echo "Step 3: Enabling Continuous Profiler (DD_PROFILING_ENABLED)..."; \
		echo "  Why: correlates CPU flame graphs with slow traces/batch steps. 5 of 6"; \
		echo "  services (not notification-service — its Go profiler is already gated"; \
		echo "  by step 1's patch):"; \
		for p in scripts/patches/instrument-sso/profiler-*.patch; do \
			svc=$$(basename $$p .patch | sed 's/^profiler-//'); \
			echo "    $$svc"; \
			patch -p1 --forward -s < $$p || true; \
		done; \
		echo ""; \
		echo "Step 4: Enabling Data Streams / Data Jobs Monitoring..."; \
		echo "  Why: DSM traces JMS producer→consumer latency and queue lag; DJM"; \
		echo "  surfaces Spring Batch job runs under APM > Data Jobs. gateway-api has"; \
		echo "  neither (no JMS produce/consume):"; \
		for p in scripts/patches/instrument-sso/dsm-*.patch scripts/patches/instrument-sso/djm-*.patch; do \
			svc=$$(basename $$p .patch | sed -e 's/^dsm-//' -e 's/^djm-//'); \
			echo "    $$svc"; \
			patch -p1 --forward -s < $$p || true; \
		done; \
		echo "  Note: fraud-detection's DSM extra is baked into requirements.txt —"; \
		echo "  needs 'make build' + redeploy, not just a redeploy, to take effect."; \
		echo ""; \
		echo "Service Catalog: service.datadog.yaml already ships for all 6 services"; \
		echo "  (static, git-committed metadata — team ownership, links, lifecycle/"; \
		echo "  tier). Nothing to patch; Datadog's GitHub integration auto-scans the"; \
		echo "  repo tree for these files once installed. See INSTRUMENTATION.md."; \
		touch .instrumentation-applied; \
		echo ""; \
		echo "✓ Instrumentation enabled. Redeploy to activate:"; \
		$(print_redeploy_hint); \
	fi

## uninstrument: [Datadog Instrumentation] Reverse all four make instrument steps (Data Streams/Data Jobs
##               Monitoring, then Continuous Profiler, then Single Step
##               Instrumentation gating, then APM custom-span patches — opposite
##               order from make instrument). Restores every file to its original
##               commented-out state. Service Catalog files are static and
##               unaffected either way.
##
##               After patching, redeploy (rollout restart alone won't pick up the
##               reverted env vars/annotations — the manifests must be re-applied):
##                 Local:  make build && load images into k3s && make deploy-k8s
##                 EKS:    make build-ecr && make deploy-k8s-eks
uninstrument:
	@if [ ! -f .instrumentation-applied ]; then \
		echo "Instrumentation is not currently enabled (nothing to reverse)."; \
	else \
		echo "Reversing Data Streams / Data Jobs Monitoring patches..."; \
		for p in scripts/patches/instrument-sso/dsm-*.patch scripts/patches/instrument-sso/djm-*.patch; do \
			svc=$$(basename $$p .patch | sed -e 's/^dsm-//' -e 's/^djm-//'); \
			echo "  $$svc"; \
			patch -p1 --reverse -s < $$p || true; \
		done; \
		echo "Reversing Continuous Profiler patches..."; \
		for p in scripts/patches/instrument-sso/profiler-*.patch; do \
			svc=$$(basename $$p .patch | sed 's/^profiler-//'); \
			echo "  $$svc"; \
			patch -p1 --reverse -s < $$p || true; \
		done; \
		echo "Reversing Single Step Instrumentation gating patches..."; \
		for p in scripts/patches/instrument-sso/sso-*.patch; do \
			svc=$$(basename $$p .patch | sed 's/^sso-//'); \
			echo "  $$svc"; \
			patch -p1 --reverse -s < $$p || true; \
		done; \
		echo "Reversing APM custom-span patches..."; \
		for p in scripts/patches/*.patch; do \
			svc=$$(basename $$p .patch); \
			echo "  $$svc"; \
			patch -p1 --reverse -s < $$p || true; \
		done; \
		rm -f .instrumentation-applied; \
		echo ""; \
		echo "✓ Instrumentation disabled. Redeploy to deactivate:"; \
		$(print_redeploy_hint); \
	fi

## tags: [Datadog Instrumentation] Enable Unified Service Tagging (env/service/version) + log injection
##       + log collection autodiscovery. Three-step, narrated: (a) UST pod
##       labels + DD_ENV/DD_SERVICE/DD_VERSION env vars in the Kubernetes
##       manifests, (b) trace_id/span_id log injection (Python
##       patch_logging(), Node dd-trace logInjection, Java DD_LOGS_INJECTION,
##       Go manual field injection), (c) the ad.datadoghq.com/<service>.logs
##       pod annotation the Agent uses for log source/service tagging.
##       Applies unified diff patches from scripts/patches/tags/ — a separate
##       directory from scripts/patches/*.patch, so this never interacts with
##       make instrument/uninstrument. Fully reversible with make untag.
##       Idempotent: a second run is a clean no-op (tracked via .tags-applied).
##
##       NOTE: the Go log-injection block references the 'alert.send' span
##       created by 'make instrument' — run 'make instrument' first if you
##       want notification-service log correlation to actually compile/work.
##       transaction-service has the same ordering requirement: its
##       'logInjection: true' line lives inside the dd-trace tracer-init
##       block, which is itself gated behind 'make instrument' — run that
##       first if you want transaction-service log correlation to apply.
##
##       After patching, redeploy (rollout restart alone won't pick up the new
##       DD_ENV/DD_SERVICE/DD_VERSION env vars/labels/annotations — the
##       manifests must be re-applied):
##         Local:  make build && load images into k3s && make deploy-k8s
##         EKS:    make build-ecr && make deploy-k8s-eks
tags:
	@if [ -f .tags-applied ]; then \
		echo "Tags + log injection already enabled. Run 'make untag' first to reapply."; \
	else \
		echo "Step (a): Enabling Unified Service Tagging (env/service/version)..."; \
		echo "  Why: DD_ENV/DD_SERVICE/DD_VERSION (+ tags.datadoghq.com/* pod labels) are what"; \
		echo "  let Datadog group traces/logs/metrics by service and correlate deploys via"; \
		echo "  Deployment Tracking. Uncommenting now in the Kubernetes manifests:"; \
		for p in scripts/patches/tags/ust-*.patch; do \
			svc=$$(basename $$p .patch | sed 's/^ust-//'); \
			echo "    $$svc"; \
			patch -p1 --forward -s < $$p || true; \
		done; \
		echo ""; \
		echo "Step (b): Enabling log injection (trace_id/span_id correlation)..."; \
		echo "  Why: without this, JSON logs and APM traces exist independently — this"; \
		echo "  stitches them so 'View in APM' works from Log Management."; \
		for p in scripts/patches/tags/loginject-*.patch; do \
			svc=$$(basename $$p .patch | sed 's/^loginject-//'); \
			echo "    $$svc"; \
			patch -p1 --forward -s < $$p || true; \
		done; \
		echo ""; \
		echo "Step (c): Enabling log collection autodiscovery annotation..."; \
		echo "  Why: ad.datadoghq.com/<service>.logs tells the Agent which log source"; \
		echo "  and service name to tag this pod's stdout/stderr logs with — required"; \
		echo "  for correct parsing/faceting in Log Management. Uncommenting now on"; \
		echo "  all 6 service manifests:"; \
		for p in scripts/patches/tags/logs-*.patch; do \
			svc=$$(basename $$p .patch | sed 's/^logs-//'); \
			echo "    $$svc"; \
			patch -p1 --forward -s < $$p || true; \
		done; \
		touch .tags-applied; \
		echo ""; \
		echo "✓ Tags + log injection enabled. Redeploy to activate:"; \
		$(print_redeploy_hint); \
	fi

## untag: [Datadog Instrumentation] Re-comment all UST + log-injection blocks (reverse of make tags).
##        Restores every file to its original commented-out state.
##
##        After patching, redeploy (rollout restart alone won't pick up the
##        reverted env vars/labels — the manifests must be re-applied):
##          Local:  make build && load images into k3s && make deploy-k8s
##          EKS:    make build-ecr && make deploy-k8s-eks
untag:
	@if [ ! -f .tags-applied ]; then \
		echo "Tags + log injection are not currently enabled (nothing to reverse)."; \
	else \
		echo "Reversing log collection autodiscovery annotation patches..."; \
		for p in scripts/patches/tags/logs-*.patch; do \
			svc=$$(basename $$p .patch | sed 's/^logs-//'); \
			echo "  $$svc"; \
			patch -p1 --reverse -s < $$p || true; \
		done; \
		echo "Reversing log injection patches..."; \
		for p in scripts/patches/tags/loginject-*.patch; do \
			svc=$$(basename $$p .patch | sed 's/^loginject-//'); \
			echo "  $$svc"; \
			patch -p1 --reverse -s < $$p || true; \
		done; \
		echo "Reversing Unified Service Tagging patches..."; \
		for p in scripts/patches/tags/ust-*.patch; do \
			svc=$$(basename $$p .patch | sed 's/^ust-//'); \
			echo "  $$svc"; \
			patch -p1 --reverse -s < $$p || true; \
		done; \
		rm -f .tags-applied; \
		echo ""; \
		echo "✓ Tags + log injection disabled. Redeploy to deactivate:"; \
		$(print_redeploy_hint); \
	fi

## dem: [Datadog Instrumentation] Enable Digital Experience Monitoring (Browser RUM + Session Replay) for the
##      finance-frontend dashboard. Creates the RUM application via a DIRECT Datadog
##      API call (NOT Terraform — 'make tf-apply-dd' no longer owns RUM), uncomments
##      the RUM <script> block in frontend-stub/index.html (scripts/patches/dem/
##      dem-frontend.patch — it ships fully commented out, like every other
##      Datadog block in this repo), then injects the resulting applicationId/
##      clientToken into it. Idempotent: checks for an existing 'finance-frontend'
##      RUM application first (tracked via .dem-applied + .dem-state.json, which
##      caches the id/client_token so re-runs and 'make undem' don't need to
##      re-query the API). Reversible with make undem. Credentials resolved from
##      .env via the same logic as create-dd-secret / tf-apply-dd (shared
##      'resolve_dd_keys' canned recipe — no $(MAKE) recipe call, so
##      'make -n dem' stays a true dry-run).
##
##      After creating, redeploy the frontend ConfigMap (HTML is served from a
##      ConfigMap, not the container image — a plain rollout restart isn't enough):
##        kubectl create configmap frontend-dashboard --from-file=index.html=frontend-stub/index.html -n finance --dry-run=client -o yaml | kubectl apply -f -
##        kubectl rollout restart deployment/frontend -n finance
dem:
	@if [ -f .dem-applied ]; then \
		echo "DEM (Digital Experience Monitoring) already enabled. Run 'make undem' first to reapply."; \
	else \
		echo "==> Digital Experience Monitoring (DEM): Browser RUM + Session Replay"; \
		echo "  Why: RUM captures real browser sessions for the finance dashboard — page"; \
		echo "  loads, clicks, errors — and Session Replay lets you watch exactly what a"; \
		echo "  user saw. This is the frontend counterpart to 'make instrument', which"; \
		echo "  only covers backend APM spans."; \
		echo ""; \
		echo "==> Resolving Datadog credentials (DD_API_KEY / DD_APP_KEY)..."; \
		$(resolve_dd_keys); \
		if [ -z "$$API_KEY" ] || [ -z "$$APP_KEY" ]; then \
			echo "ERROR: could not resolve DD_API_KEY/DD_APP_KEY for 'make dem'."; \
			echo "       cp .env.example .env && set DD_API_KEY / DD_APP_KEY to real values (not REPLACE_ME)."; \
			exit 1; \
		fi; \
		DD_SITE=$$(grep '^DD_SITE=' .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'"); \
		if [ -z "$$DD_SITE" ]; then DD_SITE=datadoghq.com; fi; \
		echo "  ✓ credentials resolved (source: $$DD_KEY_SRC; site: $$DD_SITE)"; \
		echo ""; \
		echo "==> Checking for an existing 'finance-frontend' RUM application..."; \
		LIST_JSON=$$(curl -s -H "DD-API-KEY: $$API_KEY" -H "DD-APPLICATION-KEY: $$APP_KEY" \
			"https://api.$$DD_SITE/api/v2/rum/applications"); \
		EXISTING_ID=$$(echo "$$LIST_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(next((a['id'] for a in d.get('data',[]) if a.get('attributes',{}).get('name')=='finance-frontend'), ''))" 2>/dev/null); \
		if [ -n "$$EXISTING_ID" ]; then \
			echo "  Found existing RUM application (id: $$EXISTING_ID) — reusing it, no duplicate created."; \
			APP_JSON=$$(curl -s -H "DD-API-KEY: $$API_KEY" -H "DD-APPLICATION-KEY: $$APP_KEY" \
				"https://api.$$DD_SITE/api/v2/rum/applications/$$EXISTING_ID"); \
		else \
			echo "  None found — creating a new Browser RUM application named 'finance-frontend'..."; \
			APP_JSON=$$(curl -s -X POST \
				-H "DD-API-KEY: $$API_KEY" -H "DD-APPLICATION-KEY: $$APP_KEY" \
				-H "Content-Type: application/json" \
				-d '{"data":{"type":"rum_application_create","attributes":{"name":"finance-frontend","type":"browser"}}}' \
				"https://api.$$DD_SITE/api/v2/rum/applications"); \
		fi; \
		RUM_APP_ID=$$(echo "$$APP_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('id',''))" 2>/dev/null); \
		RUM_TOKEN=$$(echo "$$APP_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('attributes',{}).get('client_token',''))" 2>/dev/null); \
		if [ -z "$$RUM_APP_ID" ] || [ -z "$$RUM_TOKEN" ]; then \
			echo "ERROR: could not create/fetch the RUM application. API response:"; \
			echo "$$APP_JSON"; \
			exit 1; \
		fi; \
		echo "  ✓ RUM application ready (id: $$RUM_APP_ID)"; \
		printf '{\n  "id": "%s",\n  "client_token": "%s",\n  "name": "finance-frontend"\n}\n' "$$RUM_APP_ID" "$$RUM_TOKEN" > .dem-state.json; \
		touch .dem-applied; \
		echo ""; \
		echo "==> Uncommenting the RUM <script> block in frontend-stub/index.html..."; \
		patch -p1 --forward -s < scripts/patches/dem/dem-frontend.patch || true; \
		echo "  ✓ RUM script block active"; \
		echo ""; \
		echo "==> Injecting RUM credentials into frontend-stub/index.html..."; \
		sed -i '' "s|'REPLACE_WITH_APPLICATION_ID'|'$$RUM_APP_ID'|g" frontend-stub/index.html; \
		sed -i '' "s|'REPLACE_WITH_CLIENT_TOKEN'|'$$RUM_TOKEN'|g" frontend-stub/index.html; \
		echo "  ✓ RUM credentials injected"; \
		echo ""; \
		echo "✓ DEM enabled. Frontend HTML is served from a ConfigMap, not the image —"; \
		echo "  rebuild it and restart to activate:"; \
		echo "    kubectl create configmap frontend-dashboard \\"; \
		echo "      --from-file=index.html=frontend-stub/index.html \\"; \
		echo "      -n finance --dry-run=client -o yaml | kubectl apply -f -"; \
		echo "    kubectl rollout restart deployment/frontend -n finance"; \
	fi

## undem: [Datadog Instrumentation] Delete the RUM application via the Datadog API and restore the frontend
##        RUM placeholders (reverse of make dem). Removes .dem-applied and
##        .dem-state.json. Fails gracefully (no cryptic curl error) if
##        DD_API_KEY/DD_APP_KEY can't be resolved.
undem:
	@if [ ! -f .dem-applied ]; then \
		echo "DEM is not currently enabled (nothing to reverse)."; \
	else \
		echo "==> Resolving Datadog credentials (DD_API_KEY / DD_APP_KEY)..."; \
		$(resolve_dd_keys); \
		if [ -z "$$API_KEY" ] || [ -z "$$APP_KEY" ]; then \
			echo "ERROR: could not resolve DD_API_KEY/DD_APP_KEY for 'make undem'."; \
			echo "       cp .env.example .env && set DD_API_KEY / DD_APP_KEY to real values (not REPLACE_ME)."; \
			echo "       The RUM application will NOT be deleted from Datadog. Local state"; \
			echo "       (.dem-applied / .dem-state.json) and the frontend placeholders are"; \
			echo "       left untouched — retry once credentials are available."; \
			exit 1; \
		fi; \
		DD_SITE=$$(grep '^DD_SITE=' .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'"); \
		if [ -z "$$DD_SITE" ]; then DD_SITE=datadoghq.com; fi; \
		RUM_APP_ID=""; \
		if [ -f .dem-state.json ]; then \
			RUM_APP_ID=$$(python3 -c "import json; print(json.load(open('.dem-state.json')).get('id',''))" 2>/dev/null); \
		fi; \
		if [ -n "$$RUM_APP_ID" ]; then \
			echo "==> Deleting RUM application (id: $$RUM_APP_ID) via the Datadog API..."; \
			HTTP_CODE=$$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
				-H "DD-API-KEY: $$API_KEY" -H "DD-APPLICATION-KEY: $$APP_KEY" \
				"https://api.$$DD_SITE/api/v2/rum/applications/$$RUM_APP_ID"); \
			if [ "$$HTTP_CODE" = "204" ] || [ "$$HTTP_CODE" = "404" ]; then \
				echo "  ✓ RUM application deleted (or already gone)"; \
			else \
				echo "  ⚠  Unexpected HTTP $$HTTP_CODE deleting RUM application — check manually in the Datadog UI."; \
			fi; \
		else \
			echo "  ⚠  No RUM application id found in .dem-state.json — skipping API delete."; \
		fi; \
		echo "==> Restoring RUM credential placeholders..."; \
		sed -i '' \
			"s|'[a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}'|'REPLACE_WITH_APPLICATION_ID'|g" \
			frontend-stub/index.html; \
		sed -i '' \
			"s|clientToken:             '[a-z0-9]*'|clientToken:             'REPLACE_WITH_CLIENT_TOKEN'|g" \
			frontend-stub/index.html; \
		echo "  ✓ RUM placeholders restored"; \
		echo ""; \
		echo "==> Re-commenting the RUM <script> block in frontend-stub/index.html..."; \
		patch -p1 --reverse -s < scripts/patches/dem/dem-frontend.patch || true; \
		rm -f .dem-applied .dem-state.json; \
		echo "  ✓ RUM script block commented out"; \
		echo ""; \
		echo "✓ DEM disabled. Redeploy to deactivate:"; \
		echo "    kubectl create configmap frontend-dashboard \\"; \
		echo "      --from-file=index.html=frontend-stub/index.html \\"; \
		echo "      -n finance --dry-run=client -o yaml | kubectl apply -f -"; \
		echo "    kubectl rollout restart deployment/frontend -n finance"; \
	fi

## build: [Build & Test] Build all service images for the local platform.
##        Images are tagged finance-sample-app-<service>:latest and :<DD_VERSION> (git short SHA).
##        Docker Desktop / Rancher Desktop: images are available in the cluster immediately.
##        Other tools — load after building:
##          kind:     kind load docker-image finance-sample-app-<svc>:latest
##          k3d:      k3d image import finance-sample-app-<svc>:latest
##          minikube: minikube image load finance-sample-app-<svc>:latest
##        Then rolling-restart to pick up new images:
##          kubectl rollout restart deployment -n finance
build:
	@echo "Building all service images (DD_VERSION=$(DD_VERSION))..."
	@for svc in gateway-api account-service transaction-service fraud-detection notification-service batch-processor; do \
		echo "  → $$svc"; \
		docker build -t finance-sample-app-$$svc:latest \
		             -t finance-sample-app-$$svc:$(DD_VERSION) \
		             --build-arg DD_VERSION=$(DD_VERSION) \
		             ./$$svc; \
	done
	@echo ""
	@echo "✓ All images built. To deploy to local k3s:"
	@echo "  # Docker Desktop/Rancher Desktop: images available immediately — no load step needed."
	@echo "  # kind:     kind load docker-image finance-sample-app-<svc>:latest"
	@echo "  # k3d:      k3d image import finance-sample-app-<svc>:latest"
	@echo "  # minikube: minikube image load finance-sample-app-<svc>:latest"
	@echo "  kubectl rollout restart deployment -n finance"

## build-ecr: [Build & Test] Build all service images for linux/amd64 and push directly to ECR.
##            Use this when deploying to EKS from an Apple Silicon (ARM) Mac.
##            Requires: ECR login (eval "$(cd deploy/terraform/aws && terraform output -raw ecr_login_command)")
##            Uses Docker Buildx cross-compilation — no QEMU emulation, safe on ARM.
##            Requires: terraform apply must have completed (make tf-apply-aws)
build-ecr:
	@if [ ! -f deploy/terraform/aws/staging.tfvars ]; then \
		echo "Error: deploy/terraform/aws/staging.tfvars not found."; \
		echo "       Copy staging.tfvars.example and fill in your values first."; \
		exit 1; \
	fi
	@cd deploy/terraform/aws && terraform output ecr_registry_urls >/dev/null 2>&1 || { \
		echo "Error: terraform output ecr_registry_urls failed."; \
		echo "       Run 'make tf-apply-aws' before 'make build-ecr'."; \
		exit 1; \
	}
	@ECR_URLS=$$(cd deploy/terraform/aws && terraform output -json ecr_registry_urls); \
	for SVC in gateway-api account-service transaction-service fraud-detection notification-service batch-processor; do \
		ECR_URL=$$(echo "$$ECR_URLS" | python3 -c "import sys,json; print(json.load(sys.stdin)['$$SVC'])"); \
		echo "Building $$SVC -> $$ECR_URL"; \
		docker buildx build --platform linux/amd64 --push \
			-t $${ECR_URL}:$(DD_VERSION) \
			-t $${ECR_URL}:latest \
			./$$SVC; \
	done

## test: [Build & Test] Run the e2e test suite against the running stack.
##       Prerequisites: make deploy-k8s (uses Python stdlib only — no pip install required).
##       Note: requires kubectl port-forward or NodePort access to the services.
##       For a no-setup check, watch the in-cluster traffic generator instead:
##         kubectl logs -n finance deploy/traffic-generator -f
test:
	python3 scripts/test-e2e.py

## test-traffic: [Build & Test] Run the traffic generator locally for a fixed duration.
##               The in-cluster traffic-generator Deployment already runs continuously.
##               Use this to temporarily boost traffic or test from your laptop.
##               Note: requires services reachable on localhost (kubectl port-forward).
test-traffic:
	python3 scripts/generate-traffic.py --rate 2 --duration 60



## deploy-k8s: [Local Kubernetes] Deploy the Finance app to Kubernetes without Datadog.
##             Creates the 'finance' namespace and all infrastructure + application services.
##             Prerequisites:
##               1. make build        — build all service images
##               2. kubectl configured — pointing at your target cluster
##             On Docker Desktop / Rancher Desktop, images built by
##             'make build' are immediately available (imagePullPolicy: IfNotPresent).
##             On kind/k3d/minikube, load images after building (see 'make build' help).
deploy-k8s:
	@echo "Creating finance namespace (idempotent)..."
	kubectl apply -f deploy/kubernetes/base/00-namespace.yaml
	@echo "Creating Keycloak realm ConfigMap..."
	@$(create_realm_cm)
	@echo "Creating TLS secret for nginx Keycloak HTTPS proxy..."
	@$(ensure_keycloak_tls)
	@echo "Applying config, secrets and infrastructure..."
	kubectl apply -f deploy/kubernetes/base/01-config.yaml
	kubectl apply -f deploy/kubernetes/base/02-secrets.yaml
	kubectl apply -f deploy/kubernetes/base/infrastructure/activemq-broker-config.yaml
	kubectl apply -f deploy/kubernetes/base/infrastructure/activemq.yaml
	kubectl apply -f deploy/kubernetes/base/infrastructure/keycloak.yaml
	kubectl apply -f deploy/kubernetes/base/infrastructure/postgres-init.yaml
	kubectl apply -f deploy/kubernetes/base/infrastructure/postgres.yaml
	kubectl apply -f deploy/kubernetes/base/infrastructure/redis.yaml
	@echo "Waiting for PostgreSQL to be ready..."
	kubectl rollout status statefulset/postgres-ledger -n finance --timeout=120s
	@echo "Creating traffic-generator script ConfigMap..."
	@$(create_traffic_cm)
	@echo "Creating frontend dashboard ConfigMap (injecting KEYCLOAK_PUBLIC_URL)..."
	@$(create_frontend_cm)
	@echo "Applying application services (pinning DD version=$(DD_VERSION))..."
	@for f in account-service batch-processor fraud-detection frontend gateway-api notification-service transaction-service traffic-generator; do \
		echo "  → $$f"; \
		DD_VERSION=$(DD_VERSION) bash scripts/pin-dd-version.sh \
			< deploy/kubernetes/base/services/$$f.yaml | kubectl apply -f -; \
	done
	@echo ""
	@echo "✓  Deployed. Check pod status:"
	@echo "     kubectl get pods -n finance"
	@echo "   Dashboard available at: http://localhost:30080"
	@echo "   (or: kubectl port-forward svc/frontend 3000:80 -n finance)"
	@echo ""
	@echo "⚠  Keycloak on :30443 uses a self-signed HTTPS cert (local-only —"
	@echo "   EKS uses a real ACM cert instead). Before your first login on the"
	@echo "   dashboard, open https://localhost:30443 once and accept the browser"
	@echo "   security warning (Advanced → Accept the Risk in Firefox, Advanced →"
	@echo "   Proceed in Chrome). Skipping this makes dashboard login fail with a"
	@echo "   network/fetch error. This only affects browser access — the in-cluster"
	@echo "   traffic-generator talks to Keycloak over plain HTTP and is unaffected."

## check-eks-kubeconfig: [AWS / Terraform] Verify kubectl can actually reach the EKS cluster,
##                       auto-refreshing via tf-configure-kubectl if not. kubeconfig stores a
##                       static snapshot of the cluster's API endpoint — if the cluster was
##                       destroyed and recreated (even under the same name) since kubeconfig
##                       was last written, that endpoint is dead (DNS no longer resolves) and
##                       nothing detects it automatically. This makes that self-healing.
check-eks-kubeconfig:
	@if ! kubectl get nodes --request-timeout=5s >/dev/null 2>&1; then \
		echo "    kubectl can't reach the cluster (stale kubeconfig?) — refreshing via tf-configure-kubectl..."; \
		$(MAKE) tf-configure-kubectl; \
		if ! kubectl get nodes --request-timeout=5s >/dev/null 2>&1; then \
			echo "    ERROR: still can't reach the EKS cluster after refreshing kubeconfig."; \
			echo "           Check that 'make tf-apply-aws' has completed and your AWS SSO session is still valid."; \
			exit 1; \
		fi; \
	fi

## deploy-k8s-eks: [AWS / Terraform] Deploy to EKS using Kustomize overlay.
##                 Patches base manifests with ECR image URLs, gp3 StorageClass,
##                 and imagePullPolicy:Always. Safe to re-run (idempotent).
##                 Prerequisites: make tf-apply-aws, make build-ecr. (kubeconfig freshness
##                 is checked automatically via check-eks-kubeconfig.)
##                 Export FE_URL and DASH_URL first (see README's AWS EKS walkthrough) to
##                 get a working Keycloak login on the very first deploy — no post-deploy
##                 patch or restart needed. Without them, see the fallback instructions
##                 printed at the end of this target.
deploy-k8s-eks: check-eks-kubeconfig
	bash scripts/generate-eks-kustomization.sh
	@echo "Creating finance namespace (idempotent)..."
	kubectl apply -f deploy/kubernetes/base/00-namespace.yaml
	@echo "Creating Keycloak realm ConfigMap..."
	@FE_URL="$(FE_URL)" DASH_URL="$(DASH_URL)"; $(create_realm_cm)
	@echo "Applying config and secrets..."
	kubectl apply -f deploy/kubernetes/base/01-config.yaml
	@if [ -n "$(FE_URL)" ]; then \
		echo "FE_URL set — patching app-config's KEYCLOAK_PUBLIC_URL before Keycloak starts..."; \
		kubectl patch configmap app-config -n finance --type=merge -p "{\"data\":{\"KEYCLOAK_PUBLIC_URL\":\"$(FE_URL)\"}}"; \
	fi
	kubectl apply -f deploy/kubernetes/base/02-secrets.yaml
	@echo "Creating traffic-generator script ConfigMap..."
	@$(create_traffic_cm)
	@echo "Creating TLS secret for nginx Keycloak HTTPS proxy (idempotent)..."
	@$(ensure_keycloak_tls)
	@echo "Creating frontend dashboard ConfigMap (injecting current KEYCLOAK_PUBLIC_URL)..."
	@FE_URL="$(FE_URL)" $(create_frontend_cm)
	@echo "Applying EKS overlay (ECR images + gp3 StorageClass + infrastructure + services; pinning DD version=$(DD_VERSION))..."
	kubectl kustomize deploy/kubernetes/overlays/eks \
		| DD_VERSION=$(DD_VERSION) bash scripts/pin-dd-version.sh \
		| kubectl apply -f -
	@echo "Waiting for PostgreSQL to be ready..."
	kubectl rollout status statefulset/postgres-ledger -n finance --timeout=120s
	@echo ""
	@echo "✓  Deployed. Check pod status:"
	@echo "     kubectl get pods -n finance"
	@echo ""
ifneq ($(strip $(FE_URL)),)
ifneq ($(strip $(DASH_URL)),)
	@echo "✓  FE_URL/DASH_URL were set, so KEYCLOAK_PUBLIC_URL and the Keycloak"
	@echo "   client's redirectUris/webOrigins were templated in before Keycloak's"
	@echo "   first boot — no further patching or restart needed. Just accept the"
	@echo "   certificate warning in your browser if you're on Option A (self-signed)."
else
	@echo "⚠  FE_URL was set but DASH_URL was not — app-config's KEYCLOAK_PUBLIC_URL"
	@echo "   is correct, but the Keycloak client's redirectUris/webOrigins were NOT"
	@echo "   templated (create_realm_cm needs both). Export DASH_URL too and re-run"
	@echo "   'make deploy-k8s-eks', or patch the live realm manually — see"
	@echo "   README.md's 'Update the Keycloak client's allowed origins' section."
endif
else
	@echo "⚠  Keycloak public URL (always required): FE_URL/DASH_URL were not set for"
	@echo "   this deploy, so app-config still has the default localhost value and the"
	@echo "   Keycloak client's redirectUris/webOrigins are still localhost-only."
	@echo "   The frontend Service (nginx) sits behind the Terraform-managed NLB and"
	@echo "   proxies Keycloak — the keycloak Service itself is ClusterIP-only, so"
	@echo "   Keycloak is NEVER reached via frontend_url — nginx only proxies Keycloak"
	@echo "   on its own dedicated listener(s), not the dashboard's (see"
	@echo "   deploy/kubernetes/base/services/frontend.yaml's routing table)."
	@echo "   Tip: next time, export FE_URL/DASH_URL before running 'make deploy-k8s-eks'"
	@echo "   to skip this whole patch+restart dance. For now, fix the live cluster:"
	@echo "     FE_URL=\$$(cd deploy/terraform/aws && terraform output -raw frontend_keycloak_https_url)  # Option A: self-signed"
	@echo "     # FE_URL=\$$(cd deploy/terraform/aws && terraform output -raw frontend_keycloak_acm_url)  # Option B/C: custom domain — use this line instead"
	@echo "     kubectl patch configmap app-config -n finance --type=merge -p \"{\\\"data\\\":{\\\"KEYCLOAK_PUBLIC_URL\\\":\\\"\$$FE_URL\\\"}}\""
	@echo "     sed \"s|https://localhost:30443|\$$FE_URL|g\" frontend-stub/index.html > /tmp/finance-index.html"
	@echo "     kubectl create configmap frontend-dashboard --from-file=index.html=/tmp/finance-index.html -n finance --dry-run=client -o yaml | kubectl apply -f -"
	@echo "     kubectl rollout restart deployment/keycloak deployment/frontend -n finance"
	@echo ""
	@echo "⚠  Keycloak client redirect URIs (also always required, for both"
	@echo "   options): identity-provider/realm-export/finance-realm.json"
	@echo "   hardcodes localhost origins. Without this step, login fails with"
	@echo "   'NetworkError' (Keycloak rejects the OIDC redirect/CORS from an"
	@echo "   unlisted origin) regardless of which certificate option you're"
	@echo "   using — this is CORS allow-listing, unrelated to the cert."
	@echo "   Patch the live realm via kcadm (uses the same FE_URL from above,"
	@echo "   plus \$$(terraform output -raw frontend_url) for the dashboard's"
	@echo "   own origin):"
	@echo "     DASH_URL=\$$(cd deploy/terraform/aws && terraform output -raw frontend_url)"
	@echo "     KC_POD=\$$(kubectl get pod -n finance -l app=keycloak -o jsonpath='{.items[0].metadata.name}')"
	@echo "     kubectl exec -n finance \"\$$KC_POD\" -- /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user admin --password 'Finance@Admin2025!'"
	@echo "     CLIENT_ID=\$$(kubectl exec -n finance \"\$$KC_POD\" -- /opt/keycloak/bin/kcadm.sh get clients -r finance -q clientId=finance-gateway --fields id --format csv --noquotes)"
	@echo "     kubectl exec -n finance \"\$$KC_POD\" -- /opt/keycloak/bin/kcadm.sh update \"clients/\$$CLIENT_ID\" -r finance \\"
	@echo "       -s 'redirectUris=[\"http://localhost:30080/*\",\"https://localhost:30443/*\",\"http://gateway-api:8080/*\",\"'\"\$$DASH_URL\"'/*\",\"'\"\$$FE_URL\"'/*\"]' \\"
	@echo "       -s 'webOrigins=[\"http://localhost:30080\",\"https://localhost:30443\",\"http://gateway-api:8080\",\"'\"\$$DASH_URL\"'\",\"'\"\$$FE_URL\"'\"]'"
endif

## deploy-k8s-dd: [Local Kubernetes] Deploy the Datadog Agent. Auto-detects local vs EKS.
##               Run AFTER 'make deploy-k8s' (local) or 'make deploy-k8s-eks' (EKS).
##               'create-dd-secret' runs first as a prerequisite — no separate secret
##               step needed. Keeping it a prerequisite (rather than a $(MAKE) call
##               inside the recipe) means 'make -n deploy-k8s-dd' is a true dry-run.
##
##               Both LOCAL and EKS read DD_API_KEY + DD_APP_KEY from .env (via
##               create-dd-secret) — no AWS Secrets Manager dependency.
##
##               LOCAL: installs Operator (if absent), applies the Agent config.
##               EKS:   installs Operator via Helm, applies the Bottlerocket-patched
##                      Agent overlay.
deploy-k8s-dd: create-dd-secret
	@echo "==> Detecting cluster environment..."
	@IS_EKS=$$(kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null | grep -c 'aws:///') ; \
	IS_BOTTLEROCKET=$$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.osImage}' 2>/dev/null | grep -ic 'bottlerocket') ; \
	if [ "$$IS_EKS" -gt 0 ]; then \
		echo "    Detected: EKS$$([ $$IS_BOTTLEROCKET -gt 0 ] && echo ' + Bottlerocket' || echo '')"; \
		echo "==> Installing Datadog Operator via Helm (idempotent)..."; \
		$(install_dd_operator); \
		echo "==> Applying EKS agent config (Kustomize overlay — inherits full base spec)..."; \
		kubectl apply -k deploy/kubernetes/overlays/eks-datadog; \
	else \
		echo "    Detected: local cluster"; \
		echo "==> Checking Datadog Operator is installed and running..."; \
		if ! kubectl get crd datadogagents.datadoghq.com >/dev/null 2>&1; then \
			echo "    CRD not found — installing Datadog Operator via Helm..."; \
			$(install_dd_operator); \
		elif ! kubectl get deployment datadog-operator -n datadog >/dev/null 2>&1 || \
			[ "$$(kubectl get deployment datadog-operator -n datadog -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" != "1" ]; then \
			echo "    CRD exists but Operator Deployment is missing or not available"; \
			echo "    (this happens after 'make teardown', which removes the Helm release"; \
			echo "     but not the cluster-scoped CRD) — (re)installing via Helm..."; \
			$(install_dd_operator); \
		else \
			echo "    Datadog Operator already installed and running — skipping"; \
		fi; \
		echo "==> Applying local cluster config (Kustomize base)..."; \
		kubectl apply -k deploy/kubernetes/datadog/agent; \
	fi
	@kubectl apply -f deploy/kubernetes/datadog/checks/activemq-check.yaml
	@kubectl apply -f deploy/kubernetes/datadog/checks/postgres-check.yaml
	@echo ""
	@echo "✓  Datadog Agent deploying. Verify with:"
	@echo "     kubectl get datadogagent -n datadog"
	@echo "     kubectl get daemonset datadog -n datadog"
	@echo "     kubectl get deployment datadog-cluster-agent -n datadog"

## undeploy-k8s: [Local Kubernetes] Remove all Finance app resources from Kubernetes (namespaces only).
##               Does NOT delete persistent data — use 'make teardown' for a full reset.
undeploy-k8s:
	kubectl delete namespace finance --ignore-not-found
	kubectl delete namespace datadog --ignore-not-found
	# gp3 is cluster-scoped (not namespaced) — must be deleted separately
	kubectl delete storageclass gp3 --ignore-not-found

## teardown: [Local Kubernetes] Full reset — removes all K8s resources AND cleans up persistent data.
##           Deletes:
##             - finance namespace (all app pods, services, configmaps)
##             - datadog namespace (Agent, Operator, Cluster Agent)
##             - Datadog Operator Helm release
##             - Any leftover Docker volumes (postgres, redis, artemis, keycloak)
##             - Port-forward processes
##           Safe to run even if some resources are already gone.
##
##           After teardown, start fresh with:
##             make build && make deploy-k8s && make create-dd-secret && make deploy-k8s-dd
teardown:
	@echo "==> Killing any stray kubectl port-forward processes..."
	@pkill -f 'kubectl port-forward' 2>/dev/null || true
	@echo "==> Removing Datadog Agent CRD instance..."
	@kubectl delete datadogagent datadog -n datadog --ignore-not-found 2>&1 || true
	@echo "==> Deleting finance namespace (app pods, PVCs, services)..."
	@kubectl delete namespace finance --ignore-not-found 2>&1
	@echo "==> Deleting datadog namespace (Agent DaemonSet, Cluster Agent)..."
	@kubectl delete namespace datadog --ignore-not-found 2>&1
	@echo "==> Uninstalling Datadog Operator Helm release..."
	@helm uninstall datadog-operator -n datadog 2>/dev/null || true
	@echo "==> Removing leftover Docker volumes..."
	@for vol in postgres-data redis-data artemis-data keycloak-data datadog-run; do \
		docker volume rm finance-sample-app_$$vol 2>/dev/null && echo "  removed finance-sample-app_$$vol" || true; \
	done
	@# gp3 is cluster-scoped (EKS only) — safe to ignore if not present
	@kubectl delete storageclass gp3 --ignore-not-found 2>/dev/null || true
	@echo ""
	@echo "✓  Teardown complete. Cluster and data are clean."
	@echo "   Start fresh: make build && make deploy-k8s && make create-dd-secret && make deploy-k8s-dd"

## deploy/terraform/aws/staging.tfvars: auto-created from staging.tfvars.example
##                                       on first use (self-heals a missing file
##                                       instead of failing 'terraform plan/apply'
##                                       with a raw "Failed to read variables file").
deploy/terraform/aws/staging.tfvars:
	@cp deploy/terraform/aws/staging.tfvars.example $@
	@echo "==> Created $@ from staging.tfvars.example"
	@echo "    Edit it with your aws_profile / aws_region / cluster_name, then re-run."

## tf-plan-aws: [AWS / Terraform] Initialise and plan the Terraform AWS (EKS) target.
##              Uses the AWS_PROFILE env var. Override vars: TF_AWS_VARS="-var-file=staging.tfvars -var aws_profile=<name>"
TF_AWS_VARS ?= -var-file=staging.tfvars
tf-plan-aws: deploy/terraform/aws/staging.tfvars
	cd deploy/terraform/aws && terraform init && terraform plan $(TF_AWS_VARS)

## tf-apply-aws: [AWS / Terraform] Apply the Terraform AWS plan (creates EKS, ECR, VPC, IAM).
##               WARNING: this provisions real AWS resources and incurs cost.
tf-apply-aws: deploy/terraform/aws/staging.tfvars
	bash scripts/aws-pre-apply.sh
	cd deploy/terraform/aws && terraform init && terraform apply $(TF_AWS_VARS)

## tf-configure-kubectl: [AWS / Terraform] Update kubeconfig to point kubectl at the EKS cluster.
##                       Run after tf-apply-aws before deploy-k8s.
tf-configure-kubectl:
	eval "$$(cd deploy/terraform/aws && terraform output -raw kubeconfig_command)"

## frontend-url: [AWS / Terraform] Print the public URL of the Finance app frontend on EKS.
##               Available as soon as make tf-apply-aws completes (Terraform-managed
##               NLB, not a Kubernetes LoadBalancer Service) — no need to deploy the
##               app first.
frontend-url:
	@cd deploy/terraform/aws && terraform output -raw frontend_url 2>/dev/null && echo "" \
		|| echo "No NLB yet — run 'make tf-apply-aws' first."

## tf-destroy-aws: [AWS / Terraform] Safely destroy all AWS resources created by Terraform.
##                 EKS node groups/add-ons/cluster, Secrets Manager secrets, and ECR
##                 repos are all Terraform-managed and destroy correctly on their own
##                 (module-ordered dependencies, recovery_window_in_days = 0,
##                 force_delete = true respectively). The only thing outside
##                 Terraform's state is stray, non-Terraform ELBs/ENIs, so this:
##                   1. Clears finance workloads via kubectl (best-effort) and
##                      releases any stray ELB/ENI in the VPC, excluding the
##                      Terraform-managed frontend NLB
##                   2. Runs terraform destroy for everything else
tf-destroy-aws:
	bash scripts/aws-force-destroy.sh --yes



## create-dd-secret: [Local Kubernetes] Create (or update) the datadog-secret K8s Secret in the datadog namespace.
##                   Single source of truth for both local and EKS: reads DD_API_KEY,
##                   DD_APP_KEY, and (optionally) DATADOG_DBM_PASSWORD from .env.
##                   No AWS Secrets Manager dependency — .env is authoritative on
##                   every environment, so there's nothing to fall out of sync with
##                   a Terraform re-apply.
##                   Safe to re-run — uses --dry-run=client | kubectl apply (idempotent).
##                   Run this BEFORE make deploy-k8s-dd.
create-dd-secret:
	@kubectl create namespace datadog --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null; \
	echo "==> Reading Datadog credentials from .env..."; \
	ENV_FILE=.env; \
	if [ ! -f "$$ENV_FILE" ]; then \
		echo "ERROR: $$ENV_FILE not found."; \
		echo "       Copy .env.example to .env and fill in DD_API_KEY and DD_APP_KEY."; \
		exit 1; \
	fi; \
	DD_API_KEY=$$(grep '^DD_API_KEY=' $$ENV_FILE | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'"); \
	DD_APP_KEY=$$(grep '^DD_APP_KEY=' $$ENV_FILE | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'"); \
	DBM_PASSWORD=$$(grep '^DATADOG_DBM_PASSWORD=' $$ENV_FILE | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'"); \
	if [ -z "$$DD_API_KEY" ] || [ "$$DD_API_KEY" = "REPLACE_ME" ]; then \
		echo "ERROR: DD_API_KEY not set (or still 'REPLACE_ME') in $$ENV_FILE."; exit 1; \
	fi; \
	if [ -z "$$DD_APP_KEY" ] || [ "$$DD_APP_KEY" = "REPLACE_ME" ]; then \
		echo "ERROR: DD_APP_KEY not set (or still 'REPLACE_ME') in $$ENV_FILE."; exit 1; \
	fi; \
	if [ "$$DBM_PASSWORD" = "REPLACE_ME" ]; then DBM_PASSWORD=""; fi; \
	DBM_FLAG=$$([ -n "$$DBM_PASSWORD" ] && echo "--from-literal dbm-password=$$DBM_PASSWORD" || echo ''); \
	kubectl create secret generic datadog-secret \
		--from-literal api-key="$$DD_API_KEY" \
		--from-literal app-key="$$DD_APP_KEY" \
		$$DBM_FLAG \
		--namespace datadog \
		--dry-run=client -o yaml | kubectl apply -f -; \
	echo ""; \
	echo "✓  datadog-secret created/updated in namespace datadog"; \
	echo "   Keys stored: api-key, app-key$$([ -n "$$DBM_PASSWORD" ] && echo ', dbm-password' || echo ' (dbm-password not set)')"; \
	echo "   Verify: kubectl get secret datadog-secret -n datadog -o jsonpath='{.data}' | python3 -m json.tool"

## dbm: [Datadog Instrumentation] Enable Database Monitoring (DBM) for postgres-ledger. Two-step, narrated:
##      (a) uncomments the Agent-side postgres.d check config + the
##      DD_DBM_POSTGRES_PASSWORD wiring in datadog-agent.yaml (applies
##      scripts/patches/dbm/dbm-agent.patch — a ConfigMap/env var alone does
##      nothing unless mounted like this), (b) creates/refreshes the
##      read-only 'datadog' PostgreSQL role + pg_stat_statements + the
##      explain_statement function (scripts/dbm-setup.sql) in the
##      postgres-ledger pod. Idempotent: tracked via .dbm-applied — a second
##      run is a clean no-op. Fully reversible with make undbm.
##
##      Password source (in order): the datadog-secret 'dbm-password' key,
##      else DATADOG_DBM_PASSWORD in .env. If neither is set, step (b) is
##      skipped (DBM stays off at the DB level even though the Agent-side
##      patch is applied) — this was previously 'make dbm-setup', auto-run
##      by 'make deploy-k8s-dd'; it is no longer auto-run, so run 'make dbm'
##      explicitly after 'make create-dd-secret' / 'make deploy-k8s-dd'.
##
##      After patching, redeploy the Agent to pick up the new mount:
##        Local: kubectl apply -k deploy/kubernetes/datadog/agent && kubectl rollout restart daemonset/datadog-agent -n datadog
##        EKS:   kubectl apply -k deploy/kubernetes/overlays/eks-datadog && kubectl rollout restart daemonset/datadog-agent -n datadog
dbm:
	@if [ -f .dbm-applied ]; then \
		echo "DBM already enabled. Run 'make undbm' first to reapply."; \
	else \
		echo "Step (a): Enabling Agent-side Database Monitoring config..."; \
		echo "  Why: DD_DBM_POSTGRES_PASSWORD + the postgres.d check ConfigMap mount"; \
		echo "  are what let the Agent authenticate to Postgres and collect query"; \
		echo "  metrics/samples. Uncommenting now in datadog-agent.yaml:"; \
		patch -p1 --forward -s < scripts/patches/dbm/dbm-agent.patch || true; \
		touch .dbm-applied; \
		echo ""; \
		echo "Step (b): Creating/refreshing the PostgreSQL 'datadog' monitoring role..."; \
		DBM_PASSWORD=$$(kubectl get secret datadog-secret -n datadog -o jsonpath='{.data.dbm-password}' 2>/dev/null | base64 -d 2>/dev/null); \
		if [ -z "$$DBM_PASSWORD" ] && [ -f .env ]; then \
			DBM_PASSWORD=$$(grep '^DATADOG_DBM_PASSWORD=' .env | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'"); \
		fi; \
		if [ "$$DBM_PASSWORD" = "REPLACE_ME" ]; then DBM_PASSWORD=""; fi; \
		if [ -z "$$DBM_PASSWORD" ]; then \
			echo "  ⚠  no DBM password (datadog-secret dbm-password / DATADOG_DBM_PASSWORD) — skipping (DBM stays off at the DB level)."; \
		elif ! kubectl get statefulset postgres-ledger -n finance >/dev/null 2>&1; then \
			echo "  ⚠  postgres-ledger not found in namespace finance — run 'make deploy-k8s' first. Skipping."; \
		else \
			if kubectl exec -i -n finance statefulset/postgres-ledger -- \
				psql -U finance -d ledger -v ON_ERROR_STOP=1 -v dbm_password="$$DBM_PASSWORD" -f - < scripts/dbm-setup.sql; then \
				echo "  ✓ DBM role 'datadog' ready (pg_monitor + pg_stat_statements + explain_statement)."; \
			else \
				echo "  ⚠  SQL failed — check postgres-ledger is Ready. DBM will not authenticate until this succeeds."; \
			fi; \
		fi; \
		echo ""; \
		echo "✓ DBM enabled. Redeploy the Agent to pick up the new mount:"; \
		echo "    Local: kubectl apply -k deploy/kubernetes/datadog/agent && kubectl rollout restart daemonset/datadog-agent -n datadog"; \
		echo "    EKS:   kubectl apply -k deploy/kubernetes/overlays/eks-datadog && kubectl rollout restart daemonset/datadog-agent -n datadog"; \
	fi

## undbm: [Datadog Instrumentation] Disable Database Monitoring (DBM) — reverse of make dbm. Re-comments
##        the Agent-side postgres.d config (reverses dbm-agent.patch) and runs
##        scripts/dbm-teardown.sql to revoke the 'datadog' PostgreSQL role's
##        grants and drop the role (pg_stat_statements extension is left
##        installed — it's server-wide, not scoped to this role).
undbm:
	@if [ ! -f .dbm-applied ]; then \
		echo "DBM is not currently enabled (nothing to reverse)."; \
	else \
		echo "Step (a): Reversing the PostgreSQL 'datadog' monitoring role..."; \
		if kubectl get statefulset postgres-ledger -n finance >/dev/null 2>&1; then \
			if kubectl exec -i -n finance statefulset/postgres-ledger -- \
				psql -U finance -d ledger -v ON_ERROR_STOP=1 -f - < scripts/dbm-teardown.sql; then \
				echo "  ✓ DBM role 'datadog' revoked/dropped."; \
			else \
				echo "  ⚠  SQL failed — check postgres-ledger is Ready. Continuing to reverse the Agent-side config anyway."; \
			fi; \
		else \
			echo "  ⚠  postgres-ledger not found in namespace finance — skipping SQL teardown."; \
		fi; \
		echo ""; \
		echo "Step (b): Reversing Agent-side Database Monitoring config..."; \
		patch -p1 --reverse -s < scripts/patches/dbm/dbm-agent.patch || true; \
		rm -f .dbm-applied; \
		echo ""; \
		echo "✓ DBM disabled. Redeploy the Agent to deactivate:"; \
		echo "    Local: kubectl apply -k deploy/kubernetes/datadog/agent && kubectl rollout restart daemonset/datadog-agent -n datadog"; \
		echo "    EKS:   kubectl apply -k deploy/kubernetes/overlays/eks-datadog && kubectl rollout restart daemonset/datadog-agent -n datadog"; \
	fi

## security: [Datadog Instrumentation] Enable Application/Cloud Security (ASM Threats+SCA, CWS, CSPM).
##           Two narrated steps, one sentinel: (1) Agent-side —
##           scripts/patches/security/agent-security.patch uncomments the
##           asm/cws/cspm feature blocks in datadog-agent.yaml, (2) App-side —
##           scripts/patches/security/appsec-<service>.patch (all 6 services)
##           uncomments each service's DD_APPSEC_ENABLED env entry. Idempotent:
##           tracked via .security-applied — a second run is a clean no-op.
##           Fully reversible with make unsecurity.
##
##           After patching, redeploy (rollout restart alone won't pick up the
##           new DD_APPSEC_ENABLED env var — the manifests must be re-applied):
##             Agent: kubectl apply -k deploy/kubernetes/datadog/agent && kubectl rollout restart daemonset/datadog-agent -n datadog
##             Apps:  make build && load images into k3s && make deploy-k8s
security:
	@if [ -f .security-applied ]; then \
		echo "Security already enabled. Run 'make unsecurity' first to reapply."; \
	else \
		echo "Step (a): Enabling Agent-side security (ASM Threats/SCA, CWS, CSPM)..."; \
		echo "  Why: these agent features turn on the threat-intake pipeline, eBPF"; \
		echo "  runtime monitoring, and CIS benchmark checks. Uncommenting now in"; \
		echo "  datadog-agent.yaml:"; \
		patch -p1 --forward -s < scripts/patches/security/agent-security.patch || true; \
		echo ""; \
		echo "Step (b): Enabling App-side AppSec (DD_APPSEC_ENABLED)..."; \
		echo "  Why: the tracer needs DD_APPSEC_ENABLED=true to actually instrument"; \
		echo "  requests for SQLi/XSS/SSRF/business-logic threats. Uncommenting now"; \
		echo "  on all 6 service manifests:"; \
		for p in scripts/patches/security/appsec-*.patch; do \
			svc=$$(basename $$p .patch | sed 's/^appsec-//'); \
			echo "    $$svc"; \
			patch -p1 --forward -s < $$p || true; \
		done; \
		touch .security-applied; \
		echo ""; \
		echo "✓ Security enabled. Redeploy to activate:"; \
		echo "    Agent: kubectl apply -k deploy/kubernetes/datadog/agent && kubectl rollout restart daemonset/datadog-agent -n datadog"; \
		echo "    Apps:  make build && load images into k3s && make deploy-k8s"; \
	fi

## unsecurity: [Datadog Instrumentation] Disable Application/Cloud Security (reverse of make security).
##             Restores every file to its original commented-out state.
unsecurity:
	@if [ ! -f .security-applied ]; then \
		echo "Security is not currently enabled (nothing to reverse)."; \
	else \
		echo "Reversing App-side AppSec patches..."; \
		for p in scripts/patches/security/appsec-*.patch; do \
			svc=$$(basename $$p .patch | sed 's/^appsec-//'); \
			echo "  $$svc"; \
			patch -p1 --reverse -s < $$p || true; \
		done; \
		echo "Reversing Agent-side security config..."; \
		patch -p1 --reverse -s < scripts/patches/security/agent-security.patch || true; \
		rm -f .security-applied; \
		echo ""; \
		echo "✓ Security disabled. Redeploy to deactivate:"; \
		echo "    Agent: kubectl apply -k deploy/kubernetes/datadog/agent && kubectl rollout restart daemonset/datadog-agent -n datadog"; \
		echo "    Apps:  make build && load images into k3s && make deploy-k8s"; \
	fi

## scenario-1: [Workshop Scenarios] Inject Scenario 1 (payments slow / missing index). Drops
##             idx_transactions_account_id on the live postgres-ledger pod
##             (scripts/scenarios/scenario1-drop-index.sql), turning
##             transaction-service's ledger.velocity_check query into a full
##             table scan. Requires make instrument to already be applied (that's
##             what makes the slow db.query span visible in APM/DBM). Idempotent:
##             tracked via .scenario-1-applied. Reverse with make unscenario-1.
scenario-1:
	@if [ -f .scenario-1-applied ]; then \
		echo "Scenario 1 already injected. Run 'make unscenario-1' first to reapply."; \
	elif ! kubectl get statefulset postgres-ledger -n finance >/dev/null 2>&1; then \
		echo "postgres-ledger not found in namespace finance — run 'make deploy-k8s' first."; \
	else \
		echo "Dropping idx_transactions_account_id on postgres-ledger..."; \
		if kubectl exec -i -n finance statefulset/postgres-ledger -- \
			psql -U finance -d ledger -v ON_ERROR_STOP=1 -f - < scripts/scenarios/scenario1-drop-index.sql; then \
			touch .scenario-1-applied; \
			echo ""; \
			echo "✓ Scenario 1 injected. Generate payment traffic and look for a slow"; \
			echo "  ledger.velocity_check span in APM → click 'View in DBM' for the plan."; \
		else \
			echo "⚠  SQL failed — check postgres-ledger is Ready."; \
		fi; \
	fi

## unscenario-1: [Workshop Scenarios] Reset Scenario 1 — restores idx_transactions_account_id
##               (scripts/scenarios/scenario1-restore-index.sql).
unscenario-1:
	@if [ ! -f .scenario-1-applied ]; then \
		echo "Scenario 1 is not currently injected (nothing to reset)."; \
	else \
		echo "Restoring idx_transactions_account_id on postgres-ledger..."; \
		if kubectl exec -i -n finance statefulset/postgres-ledger -- \
			psql -U finance -d ledger -v ON_ERROR_STOP=1 -f - < scripts/scenarios/scenario1-restore-index.sql; then \
			rm -f .scenario-1-applied; \
			echo "✓ Scenario 1 reset. Index restored."; \
		else \
			echo "⚠  SQL failed — check postgres-ledger is Ready."; \
		fi; \
	fi

## scenario-2: [Workshop Scenarios] Inject Scenario 2 (nightly reconciliation fails silently).
##             Sets RECONCILIATION_SCENARIO_ENABLED=true on batch-processor and
##             rolls it out, which makes ReconciliationJob's reader silently
##             exclude an account range — the job still completes successfully,
##             but job.records_processed drops. Trigger a run with:
##               kubectl exec -n finance deploy/batch-processor -- curl -s -X POST localhost:8080/jobs/reconciliation
##             (or let scripts/generate-traffic.py's scenario_batch_job fire it).
##             Idempotent: tracked via .scenario-2-applied. Reverse with make unscenario-2.
scenario-2:
	@if [ -f .scenario-2-applied ]; then \
		echo "Scenario 2 already injected. Run 'make unscenario-2' first to reapply."; \
	elif ! kubectl get deployment batch-processor -n finance >/dev/null 2>&1; then \
		echo "batch-processor deployment not found in namespace finance — run 'make deploy-k8s' first."; \
	else \
		kubectl set env deployment/batch-processor -n finance RECONCILIATION_SCENARIO_ENABLED=true; \
		kubectl rollout restart deployment/batch-processor -n finance; \
		touch .scenario-2-applied; \
		echo ""; \
		echo "✓ Scenario 2 injected. Trigger POST /jobs/reconciliation and watch"; \
		echo "  job.records_processed drop in Data Jobs Monitoring — job still shows COMPLETED."; \
	fi

## unscenario-2: [Workshop Scenarios] Reset Scenario 2 — unsets RECONCILIATION_SCENARIO_ENABLED
##               on batch-processor and rolls it out.
unscenario-2:
	@if [ ! -f .scenario-2-applied ]; then \
		echo "Scenario 2 is not currently injected (nothing to reset)."; \
	else \
		kubectl set env deployment/batch-processor -n finance RECONCILIATION_SCENARIO_ENABLED-; \
		kubectl rollout restart deployment/batch-processor -n finance; \
		rm -f .scenario-2-applied; \
		echo "✓ Scenario 2 reset."; \
	fi

## scenario-3: [Workshop Scenarios] Inject Scenario 3 (fraud queue backing up / producer surge).
##             Sets FRAUD_QUEUE_DUPLICATE_FACTOR=3 on transaction-service and rolls
##             it out, tripling every payment's publish to fraud.score.queue while
##             fraud-detection (the consumer) keeps processing normally — DSM should
##             show a producer/consumer throughput mismatch, not a consumer problem.
##             Idempotent: tracked via .scenario-3-applied. Reverse with make unscenario-3.
scenario-3:
	@if [ -f .scenario-3-applied ]; then \
		echo "Scenario 3 already injected. Run 'make unscenario-3' first to reapply."; \
	elif ! kubectl get deployment transaction-service -n finance >/dev/null 2>&1; then \
		echo "transaction-service deployment not found in namespace finance — run 'make deploy-k8s' first."; \
	else \
		kubectl set env deployment/transaction-service -n finance FRAUD_QUEUE_DUPLICATE_FACTOR=3; \
		kubectl rollout restart deployment/transaction-service -n finance; \
		touch .scenario-3-applied; \
		echo ""; \
		echo "✓ Scenario 3 injected. Generate payment traffic and watch fraud.score.queue"; \
		echo "  producer throughput climb in DSM while the consumer stays flat."; \
	fi

## unscenario-3: [Workshop Scenarios] Reset Scenario 3 — sets FRAUD_QUEUE_DUPLICATE_FACTOR back
##               to 1 on transaction-service and rolls it out.
unscenario-3:
	@if [ ! -f .scenario-3-applied ]; then \
		echo "Scenario 3 is not currently injected (nothing to reset)."; \
	else \
		kubectl set env deployment/transaction-service -n finance FRAUD_QUEUE_DUPLICATE_FACTOR=1; \
		kubectl rollout restart deployment/transaction-service -n finance; \
		rm -f .scenario-3-applied; \
		echo "✓ Scenario 3 reset."; \
	fi

## tf-plan-dd: [Datadog Instrumentation] Plan the Datadog observability resources (index, pipeline, monitors, dashboard).
##             DD_API_KEY / DD_APP_KEY are resolved from .env automatically (same
##             resolve_dd_keys logic as 'create-dd-secret' / 'dem') and exported as
##             TF_VAR_datadog_api_key / TF_VAR_datadog_app_key -- no manual export needed.
##             synthetic_target_base_url and TF_VAR_keycloak_client_secret (needed by the
##             3 auth-dependent Synthetic tests) are resolved automatically -- see
##             sync-synthetics-config below.
TF_DD_VARS ?= -var-file=staging.tfvars
## deploy/terraform/datadog/staging.tfvars: auto-created from staging.tfvars.example
##                                           on first use -- self-heals a missing
##                                           file instead of failing with a raw
##                                           "Failed to read variables file" error.
deploy/terraform/datadog/staging.tfvars:
	@cp deploy/terraform/datadog/staging.tfvars.example $@
	@echo "==> Created $@ from staging.tfvars.example"
	@echo "    Edit it with your datadog_site / cluster_name, then re-run."

## sync-synthetics-config: [Datadog Instrumentation] Keep staging.tfvars's synthetic_target_base_url in sync
##                         with the live frontend NLB -- its hostname changes every time
##                         'tf-destroy-aws' + 'tf-apply-aws' recreates the load balancer, and a stale
##                         value here makes every Synthetic test in tf-apply-dd silently target a dead
##                         host. No-op if the AWS stack isn't up: a local-only cluster can't run these
##                         Synthetic tests at all without a Synthetics Private Location (not set up in
##                         this repo) since Datadog's public test locations can't reach cluster-internal
##                         DNS -- see the fallback URLs in main.tf's locals.
sync-synthetics-config: deploy/terraform/datadog/staging.tfvars
	@FRONTEND_URL=$$(cd deploy/terraform/aws && terraform output -raw frontend_url 2>/dev/null); \
	if [ -n "$$FRONTEND_URL" ]; then \
		CURRENT=$$(grep '^synthetic_target_base_url' deploy/terraform/datadog/staging.tfvars 2>/dev/null | sed 's/^[^=]*=[ ]*"//' | sed 's/"[ ]*$$//'); \
		if [ "$$CURRENT" != "$$FRONTEND_URL" ]; then \
			echo "==> Updating synthetic_target_base_url ($$CURRENT -> $$FRONTEND_URL)"; \
			if grep -q '^synthetic_target_base_url' deploy/terraform/datadog/staging.tfvars; then \
				sed -i '' "s#^synthetic_target_base_url.*#synthetic_target_base_url = \"$$FRONTEND_URL\"#" deploy/terraform/datadog/staging.tfvars; \
			else \
				echo "synthetic_target_base_url = \"$$FRONTEND_URL\"" >> deploy/terraform/datadog/staging.tfvars; \
			fi; \
		else \
			echo "==> synthetic_target_base_url already up to date."; \
		fi; \
	else \
		echo "==> No live AWS frontend NLB found (tf-apply-aws not run, or destroyed) -- leaving"; \
		echo "    synthetic_target_base_url as-is. A local-only deployment can't run these Synthetic"; \
		echo "    tests without a Synthetics Private Location (not set up in this repo)."; \
	fi

# Resolve TF_VAR_keycloak_client_secret from the live 'app-secrets' K8s Secret, in the SAME
# shell as the terraform call (env vars set in one recipe line don't survive into another
# target's recipe -- see the note on resolve_dd_keys above for why this can't be a
# prerequisite target like sync-synthetics-config).
define resolve_keycloak_secret
	KC_SECRET=$$(kubectl get secret app-secrets -n finance -o jsonpath='{.data.keycloak-client-secret}' 2>/dev/null | base64 -d 2>/dev/null); \
	if [ -z "$$KC_SECRET" ]; then \
		echo "WARNING: could not resolve the Keycloak client secret from 'app-secrets' in namespace"; \
		echo "         finance -- the 3 auth-dependent Synthetic tests (balance_check,"; \
		echo "         payment_happy_path, payment_bad_payload) will be created/updated with an"; \
		echo "         empty client_secret and will fail. Ensure the cluster is reachable and"; \
		echo "         'make deploy-k8s' / 'make deploy-k8s-eks' has run."; \
	fi; \
	export TF_VAR_keycloak_client_secret="$$KC_SECRET"
endef

tf-plan-dd: sync-synthetics-config
	@$(resolve_dd_keys); \
	if [ -z "$$API_KEY" ] || [ -z "$$APP_KEY" ]; then \
		echo "ERROR: could not resolve DD_API_KEY/DD_APP_KEY from .env for 'make tf-plan-dd'."; \
		echo "       cp .env.example .env && set DD_API_KEY / DD_APP_KEY to real values (not REPLACE_ME)."; \
		exit 1; \
	fi; \
	export TF_VAR_datadog_api_key="$$API_KEY"; \
	export TF_VAR_datadog_app_key="$$APP_KEY"; \
	$(resolve_keycloak_secret); \
	cd deploy/terraform/datadog && terraform init && terraform plan $(TF_DD_VARS)

## tf-apply-dd: [Datadog Instrumentation] Apply the Datadog resources (index, pipeline, monitors, dashboard).
##              WARNING: creates/updates live Datadog configuration.
##              DD_API_KEY / DD_APP_KEY are resolved from .env automatically -- see tf-plan-dd above.
tf-apply-dd: sync-synthetics-config
	@$(resolve_dd_keys); \
	if [ -z "$$API_KEY" ] || [ -z "$$APP_KEY" ]; then \
		echo "ERROR: could not resolve DD_API_KEY/DD_APP_KEY from .env for 'make tf-apply-dd'."; \
		echo "       cp .env.example .env && set DD_API_KEY / DD_APP_KEY to real values (not REPLACE_ME)."; \
		exit 1; \
	fi; \
	export TF_VAR_datadog_api_key="$$API_KEY"; \
	export TF_VAR_datadog_app_key="$$APP_KEY"; \
	$(resolve_keycloak_secret); \
	cd deploy/terraform/datadog && terraform init && terraform apply -auto-approve $(TF_DD_VARS)

## tf-destroy-dd: [Datadog Instrumentation] Destroy all Datadog resources created by this Terraform module.
##                WARNING: deletes the log index (and all indexed logs), monitors, dashboard, SLOs.
##                DD_API_KEY / DD_APP_KEY are resolved from .env automatically -- see tf-plan-dd above.
tf-destroy-dd: deploy/terraform/datadog/staging.tfvars
	@$(resolve_dd_keys); \
	if [ -z "$$API_KEY" ] || [ -z "$$APP_KEY" ]; then \
		echo "ERROR: could not resolve DD_API_KEY/DD_APP_KEY from .env for 'make tf-destroy-dd'."; \
		echo "       cp .env.example .env && set DD_API_KEY / DD_APP_KEY to real values (not REPLACE_ME)."; \
		exit 1; \
	fi; \
	export TF_VAR_datadog_api_key="$$API_KEY"; \
	export TF_VAR_datadog_app_key="$$APP_KEY"; \
	cd deploy/terraform/datadog && terraform init && terraform destroy -auto-approve $(TF_DD_VARS)
