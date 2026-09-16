# Module 8 — AWS/EKS Deployment

## Overview

Everything in Modules 1–7 runs identically on a local Kubernetes cluster or on AWS EKS — the
`make` targets are the same, just with an `-eks`/`-ecr` suffix at the deploy/build steps. This
module is the AWS-specific path: provisioning EKS via Terraform, pointing the app's identity
provider at a real load balancer, and tearing everything down cleanly afterward.

**Learning Objectives**
- Provision EKS/VPC/ECR/IAM via Terraform and confirm the cluster is reachable
- Understand the two AWS-specific integration points this app needs (Keycloak's public URL,
  Keycloak's allowed CORS origins) and why they don't just work automatically
- Tear down AWS resources in the correct order without leaving orphaned infrastructure

**Recommended Duration:** 1–1.5 hours (provisioning alone takes ~15–20 minutes)

**Prerequisites:** AWS CLI ≥ 2.x, an SSO profile (`aws configure sso`), Terraform ≥ 1.5.

> **RUM validation status:** Module 5's Browser RUM was validated locally in this curriculum's
> development. **It has not been validated end-to-end on AWS EKS** — if you enable `make dem` on
> an EKS deployment, treat it as untested territory rather than a confirmed working path, and
> verify it yourself before relying on it in front of a customer.

## Section 1 — Provision the Cluster

```bash
aws sso login --profile <profile>
cp deploy/terraform/aws/staging.tfvars.example deploy/terraform/aws/staging.tfvars
# edit aws_profile / aws_region / cluster_name in staging.tfvars
make tf-plan-aws && make tf-apply-aws            # provisions EKS/VPC/ECR/IAM/NLB, ~15–20 min
make tf-configure-kubectl && kubectl get nodes
```

This provisions the EKS cluster, VPC, ECR repositories, IAM roles, and a network load balancer —
everything the app needs to run on AWS instead of a local cluster.

## Section 2 — Build and Deploy

```bash
eval "$(cd deploy/terraform/aws && terraform output -raw ecr_login_command)"
make build-ecr && make deploy-k8s-eks
```

Every instrumentation stage from Modules 2–7 applies identically here — just substitute
`make deploy-k8s-eks` wherever the earlier modules said `make deploy-k8s`, and `make build-ecr`
wherever they said `make build`.

## Section 3 — Point Keycloak at the Real Load Balancer

This is the one piece of app-specific plumbing Terraform doesn't own — it manages the
infrastructure, not the frontend ConfigMap.

| Your setup | Output to use | What you get |
|---|---|---|
| No `domain_name` set | `frontend_keycloak_https_url` | Self-signed cert on `:8443` — accept the one-time browser warning |
| `domain_name` **is** set | `frontend_keycloak_acm_url` | Real ACM cert on `:9443` — no browser warning |

```bash
FE_URL=$(cd deploy/terraform/aws && terraform output -raw frontend_keycloak_https_url)   # or frontend_keycloak_acm_url
kubectl patch configmap app-config -n finance --type=merge -p "{\"data\":{\"KEYCLOAK_PUBLIC_URL\":\"$FE_URL\"}}"
sed "s|https://localhost:30443|$FE_URL|g" frontend-stub/index.html > /tmp/finance-index.html
kubectl create configmap frontend-dashboard --from-file=index.html=/tmp/finance-index.html -n finance --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment/keycloak deployment/frontend -n finance
```

**Also update Keycloak's allowed CORS origins** — the realm import file hardcodes `localhost`
origins because the NLB hostname isn't known until after `tf-apply-aws`. Skipping this makes
dashboard login fail with `NetworkError when attempting to fetch resource`:

```bash
DASH_URL=$(cd deploy/terraform/aws && terraform output -raw frontend_url)
KC_POD=$(kubectl get pod -n finance -l app=keycloak -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n finance "$KC_POD" -- /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user admin --password 'Finance@Admin2025!'
CLIENT_ID=$(kubectl exec -n finance "$KC_POD" -- /opt/keycloak/bin/kcadm.sh get clients -r finance -q clientId=finance-gateway --fields id --format csv --noquotes)
kubectl exec -n finance "$KC_POD" -- /opt/keycloak/bin/kcadm.sh update "clients/$CLIENT_ID" -r finance \
  -s "redirectUris=[\"http://localhost:30080/*\",\"https://localhost:30443/*\",\"http://gateway-api:8080/*\",\"$DASH_URL/*\",\"$FE_URL/*\"]" \
  -s "webOrigins=[\"http://localhost:30080\",\"https://localhost:30443\",\"http://gateway-api:8080\",\"$DASH_URL\",\"$FE_URL\"]"
```

> **This patch is in-memory only.** Keycloak runs in `start-dev` mode with an in-process H2
> database — any pod restart (including redeploys from Modules 2–7) wipes it back to
> `localhost`-only origins. If login suddenly fails with `Failed to fetch` again after working
> before, re-run this patch — nothing else has usually gone wrong.

## Section 4 — Add Datadog

Same target as local — DD_API_KEY/DD_APP_KEY are read from `.env` automatically:

```bash
make deploy-k8s-dd
make tf-apply-dd
```

Optionally: a real, browser-trusted HTTPS certificate via ACM if you own a domain and want to set
`domain_name`/`route53_zone_id` in `staging.tfvars` — see `deploy/terraform/aws/variables.tf` for
the full reference; not required for the lab to work.

## Section 5 — Teardown

Order matters — destroy Datadog's Terraform-managed resources before the AWS infrastructure
they reference, and always destroy AWS itself with the single-pass target rather than tearing
down pieces manually:

```bash
make tf-destroy-dd     # removes Datadog Terraform resources (monitors, dashboard, synthetics, log pipeline)
make tf-destroy-aws    # single-pass destroy — handles EKS/ECR/Secrets Manager ordering automatically
```

## Practical Exercise

**Goal:** Provision, deploy, log in, and tear down a full EKS-hosted Meridian Financial
deployment.

**Time:** 45–60 minutes (dominated by provisioning/deprovisioning wait time)

**Steps:**
1. `make tf-plan-aws && make tf-apply-aws`, confirm `kubectl get nodes` returns healthy nodes.
2. `make build-ecr && make deploy-k8s-eks`.
3. Complete the Keycloak public-URL and CORS-origin patches from Section 3.
4. Log into the Finance dashboard via the NLB URL.
5. `make deploy-k8s-dd && make tf-apply-dd` — confirm the dashboard and at least one monitor
   appear in Datadog.
6. Tear down: `make tf-destroy-dd` then `make tf-destroy-aws`.

**Expected outcome:** A working EKS deployment reachable over the network load balancer, with
Datadog resources applied and confirmed, followed by a clean, complete teardown with no orphaned
AWS resources.

## Resources & Next Steps

- AWS Integration: https://docs.datadoghq.com/integrations/amazon_web_services/
- Datadog on Kubernetes (Operator/Helm, Cluster Agent): https://docs.datadoghq.com/containers/kubernetes/
- Datadog Operator: https://github.com/DataDog/datadog-operator
- Terraform provider (Datadog resources): https://registry.terraform.io/providers/DataDog/datadog/latest/docs
- `sample/impl/README.md` — AWS EKS section, full reference for every command above
- `deploy/terraform/aws/variables.tf` — custom domain / ACM certificate reference
- `sample/impl/TROUBLESHOOTING.md` — layer-by-layer diagnostic model if the EKS path doesn't
  come up clean

This is the last module in the curriculum — from here, the deployment is fully instrumented and
diagnosable end-to-end, whether run locally (Modules 1–7) or on AWS (this module layered on top).
