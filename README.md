
> Unless explicitly stated otherwise all files in this repository are licensed under the Apache 2.0 License.
> This product includes software developed at Datadog (https://www.datadoghq.com/). Copyright 2020 Datadog, Inc.

# Datadog Partner Network Repository
This repo is a collection of resources for authorized members of the Datadog Partner Network, and is intended to help partners show and deliver the value of the Datadog platform.

In this repo, you will find things like:

  - Sandbox applications you can easily deploy to show how to monitor modern environments and services
  - Sample dashboards and monitors that demonstrate best-practices or are useful for specific integrations and use-cases
  - Example runbooks for how to conduct common investigations
  - Configurations of different products that are frequently helpful
  - Automation scripts and tooling that a partner would frequently find useful

Please consider [contributing](#contributing-and-feedback) to this repo, since it'll get much more useful with the input of our partners!

# Pulling just what you need

This repo has grown to hold a lot of sample apps and workshop content — you usually only need one. Use a sparse checkout so you only download the files for the app(s) you actually want:

```sh
git clone --filter=blob:none --sparse https://github.com/DataDog/dpn.git
cd dpn
git sparse-checkout set sandbox-apps/swagbot
```

This fetches all commit/tree metadata but skips downloading file contents up front, then materializes just `sandbox-apps/swagbot/` (plus the top-level repo files) into your working tree — full git history and remote tracking stay intact.

Need more than one app? Add paths any time:

```sh
git sparse-checkout add sandbox-apps/datadog-sample-finance
```

# Table of Contents

## Sandbox Applications

In-repo apps (clone/sparse-checkout this repo to get these):

1. [Sample Finance App](sandbox-apps/datadog-sample-finance) - A multi-service finance domain app (Python/FastAPI, Java/Spring Boot, Node.js, Go) pre-wired for Datadog APM, Logs, Metrics, Profiler, DBM, DSM, and Data Jobs.
2. [Swagbot Chatbot](sandbox-apps/swagbot) - A containerized chatbot app fully instrumented with Datadog LLM Observability and APM.
3. [Online Boutique (base)](sandbox-apps/microservices-demo-multiarch-main) - Google's multi-language microservices demo ("swagstore"), instrumented for Datadog APM/infra/logs.
4. [Online Boutique (AWS variant)](sandbox-apps/aws-microservices-demo-multiarch-main) - Same demo as above, packaged for AWS EC2/EKS deployment specifically.

Apps that already have their own dedicated public Datadog repo — go there directly instead of cloning this one:

5. [Bank of Anthos](https://github.com/DataDog/dpn-bank-of-anthos) - Retail banking sample app (Kubernetes/GKE), instrumented with the Datadog Operator for APM/RUM.
6. [Storedog](https://github.com/DataDog/storedog) - eCommerce demo app used in observability and code-security workshops.
7. [TSRE Microservices](https://github.com/DataDog/tsre-microservices) - Swagstore-based 12-microservice demo used for TSRE-led workshops.

## Monitors
See [monitors/](monitors) — currently includes a vSphere host-down composite monitor.

## Automation Tooling
See [scripts/](scripts) - includes a Datadog backup/export script and a Windows secrets-fetcher build.

## Partner Workshops
See [partner-workshops/](partner-workshops) - workshop guides for partner-led enablement sessions (e.g. LLM Observability).

## Azure Collection
A collection of resources dedicated to deployments that happen in Azure.

1. [Windows Secret Fetcher (Azure KeyVault)](./scripts/secrets-exe) - A guide on how to create an Azure KeyVault Secrets fetcher for use with [Datadog Secrets Management](https://docs.datadoghq.com/agent/guide/secrets-management/?tab=windows)

# Partner resources

- [Partner Enablement Hub](https://www.datadoghq.com/partner-enablement/) - training, certifications, and enablement content for partners
- [Partner Portal](https://partners.datadoghq.com/s/) - deal registration, MDF, and partner program administration
- [Partner Documentation](https://docs.datadoghq.com/partners/getting_started/) - technical getting-started docs for the partner program
- Questions or feedback on this repo? Email charlie@datadoghq.com

# Contributing and Feedback
Thank you for contributing! If you wish to contribute an application, dashboard, or other resources to this repo, see [CONTRIBUTING-sample-apps.md](CONTRIBUTING-sample-apps.md) for adding a sample app, or [CONTRIBUTING.md](CONTRIBUTING.md) for general contribution guidelines. If you wish to share feedback on how we can make this repo better, please email charlie@datadoghq.com.
