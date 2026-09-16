# dpn — Claude Context

## What this repo is

`dpn` is Datadog's public Partner Network repo: sandbox apps, workshop content, sample dashboards/monitors, and automation tooling that partners use to demo the Datadog platform. It is public — never add real credentials, internal-only links, or customer data here.

Most partners only need one sample app, not the whole repo. Point them at the `git sparse-checkout` instructions in [README.md](README.md) rather than a full clone.

## Repo map

| Path | What it is |
|---|---|
| `sandbox-apps/datadog-sample-finance/` | Finance domain sample app (Python/FastAPI, Java/Spring Boot, Node.js, Go), pre-wired for APM/Logs/Metrics/Profiler/DBM/DSM/Data Jobs |
| `sandbox-apps/swagbot/` | Chatbot demo instrumented for LLM Observability + APM |
| `sandbox-apps/microservices-demo-multiarch-main/` | Google's "Online Boutique" demo, base version |
| `sandbox-apps/aws-microservices-demo-multiarch-main/` | Same demo, AWS EC2/EKS deployment variant |
| `partner-workshops/` | Workshop guides (e.g. LLM Observability workshop) |
| `monitors/` | Sample monitor definitions (e.g. vSphere host-down composite) |
| `scripts/` | Automation tooling (Datadog backup/export, Azure/AWS secrets fetchers) |

Some sample apps referenced from the root `README.md` live in their **own dedicated Datadog repo** instead of here (`DataDog/dpn-bank-of-anthos`, `DataDog/storedog`, `DataDog/tsre-microservices`). Don't vendor a copy of those into `dpn` — link to them. This is the convention across Datadog's demo repos: an app gets its own repo once it's actively maintained on its own, and `dpn` either holds it directly (for smaller/less-active apps) or links out to it.

## Adding a new sample app

1. Check first whether the app already has (or should get) its own dedicated `DataDog/*` repo — if it's likely to be actively maintained independently, prefer that over adding it here, and just link to it from `README.md`.
2. If it belongs in `dpn` directly: copy the app's files into a new `sandbox-apps/<name>/` directory — don't add it as a git submodule or preserve an external fork's history.
3. Follow [CONTRIBUTING-sample-apps.md](CONTRIBUTING-sample-apps.md) for the checklist (README, setup docs, `.gitignore` for the app's language/ecosystem).
4. Add an entry to the "Sandbox Applications" table of contents in `README.md`.
5. Never commit real API keys, `.env` files, or cloud credential JSON files — this repo's `.gitignore` blocks common credential filename patterns, but review new app content before committing regardless.
