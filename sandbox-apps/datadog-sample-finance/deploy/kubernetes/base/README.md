# Kubernetes Base Deployment — Finance Sample App

This directory contains a complete, self-contained Kubernetes deployment of the
Finance sample app **without any Datadog dependency**. It is the recommended
starting point before progressively adding observability.

---

## Directory structure

```
base/
├── 00-namespace.yaml          # finance namespace
├── 01-config.yaml             # ConfigMap — non-secret application config
├── 02-secrets.yaml            # Secret template — replace placeholder values
├── infrastructure/
│   ├── postgres.yaml          # PostgreSQL 15 StatefulSet + Service + 2 Gi PVC
│   ├── redis.yaml             # Redis 7 Deployment + Service
│   ├── activemq.yaml          # ActiveMQ Artemis Deployment + Service
│   └── keycloak.yaml          # Keycloak 26 Deployment + Service (realm auto-imported)
└── services/
    ├── gateway-api.yaml       # FastAPI public gateway — ClusterIP :8080
    ├── account-service.yaml   # Spring Boot account management — ClusterIP :8081
    ├── transaction-service.yaml # Node.js payment processing — ClusterIP :8082
    ├── fraud-detection.yaml   # Python async fraud scorer (JMS consumer, no HTTP)
    ├── notification-service.yaml # Go async notifier (JMS consumer, no HTTP)
    ├── batch-processor.yaml   # Java/Spring Batch nightly reconciliation (no HTTP)
    ├── frontend.yaml          # nginx dashboard — NodePort :30080
    └── traffic-generator.yaml # In-cluster continuous load generator (no Datadog injection)
```

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Kubernetes 1.24+ | Any cluster: kind, minikube, Docker Desktop, EKS, AKS |
| `kubectl` configured | `kubectl cluster-info` must return a cluster URL |
| Docker images built | `make build` from the project root |

---

## Loading images into a local cluster

The service images are built locally (`make build`) and are not pushed to a
registry. How you make them available to pods depends on your local Kubernetes
distribution.

### Docker Desktop
Images built with `docker build` are immediately available — no extra step needed.
Docker Desktop's Kubernetes engine shares the Docker image cache.

### kind
```bash
# Load each service image into the kind cluster
for svc in gateway-api account-service transaction-service \
           fraud-detection notification-service batch-processor; do
  kind load docker-image finance-sample-app-${svc}:latest
done
```

### minikube
```bash
# Point your shell at minikube's Docker daemon, then build there
eval $(minikube docker-env)
make build
# All images are now in minikube's Docker cache
```

### Remote / cloud clusters (EKS, AKS)
Push images to a container registry your cluster can pull from:
```bash
# Example: AWS ECR
aws ecr get-login-password | docker login --username AWS --password-stdin <REGISTRY>
for svc in gateway-api account-service transaction-service \
           fraud-detection notification-service batch-processor; do
  docker tag  finance-sample-app-${svc}:latest <REGISTRY>/finance-${svc}:latest
  docker push <REGISTRY>/finance-${svc}:latest
done
# Then update the `image:` field in each service manifest to point to your registry.
```

---

## Quick start

```bash
# 1. Build service images (sets DD_VERSION to the current git SHA)
make build

# 2. Deploy everything
make deploy-k8s

# 3. Check pod status
kubectl get pods -n finance
```

Expected output (~2 minutes after deploy, 12 pods total):

```
NAME                                   READY   STATUS    RESTARTS
account-service-...                    1/1     Running   0
activemq-artemis-...                   1/1     Running   0
batch-processor-...                    1/1     Running   0
fraud-detection-...                    1/1     Running   0
frontend-...                           1/1     Running   0
gateway-api-...                        1/1     Running   0
keycloak-...                           1/1     Running   0
notification-service-...               1/1     Running   0
postgres-ledger-0                      1/1     Running   0
redis-...                              1/1     Running   0
traffic-generator-...                  1/1     Running   0
transaction-service-...                1/1     Running   0
```

---

## Accessing the stack

### Dashboard (nginx frontend)

The frontend nginx serves on **NodePort 30080**:

```bash
open http://localhost:30080
```

Or use port-forward if NodePort isn't reachable:

```bash
kubectl port-forward svc/frontend 3000:80 -n finance
open http://localhost:3000
```

### Keycloak admin console

```bash
kubectl port-forward svc/keycloak 8089:8080 -n finance
open http://localhost:8089
# admin / (value of keycloak-admin-password in 02-secrets.yaml)
```

### Gateway API direct

```bash
kubectl port-forward svc/gateway-api 8080:8080 -n finance
curl http://localhost:8080/health
```

### ActiveMQ management console

```bash
kubectl port-forward svc/activemq-artemis 8161:8161 -n finance
open http://localhost:8161/console
```

---

## Secrets

`02-secrets.yaml` contains placeholder values marked `REPLACE_BEFORE_USE`.
**Never commit real credentials.** Before applying to a real cluster:

**Option A — kubectl (simplest):**
```bash
kubectl create secret generic app-secrets \
  --from-literal=postgres-user=ledger_user \
  --from-literal=postgres-password=<strong-password> \
  --from-literal=artemis-user=artemis \
  --from-literal=artemis-password=<strong-password> \
  --from-literal=keycloak-admin-password=<strong-password> \
  --from-literal=keycloak-client-secret=<strong-secret> \
  -n finance
```

**Option B — Sealed Secrets or SOPS** for GitOps-safe encrypted secrets.

**Option C — External Secrets Operator** pulling from AWS Secrets Manager or
HashiCorp Vault.

---

## Startup ordering

Services that depend on ActiveMQ or PostgreSQL include **init containers** that
poll the relevant port before the main container starts:

| Service | Waits for |
|---|---|
| `account-service` | `postgres-ledger:5432` + `activemq-artemis:61616` |
| `batch-processor` | `postgres-ledger:5432` |
| `fraud-detection` | `activemq-artemis:61613` (STOMP) |
| `notification-service` | `activemq-artemis:61613` (STOMP) |
| `transaction-service` | `activemq-artemis:61613` (STOMP) |

ActiveMQ and Keycloak use **TCP probes** (not HTTP) because:
- ActiveMQ's Jolokia endpoint returns 302 redirects
- Keycloak 26 puts `/health/*` on its management port (9000), not the main HTTP port (8080)

---

## Tear down

```bash
make undeploy-k8s
# Removes the entire 'finance' namespace and all its resources.
# Persistent volumes (postgres-data) are also deleted.
```

---

## Adding Datadog observability

See `../datadog/README.md` for the full step-by-step guide to add the Datadog
Agent, enable APM, log collection, Database Monitoring, and Data Streams Monitoring.

```bash
# After completing the prerequisites in ../datadog/README.md:
make deploy-k8s-dd
```
