
> Unless explicitly stated otherwise all files in this repository are licensed under the Apache 2.0 License.
> This product includes software developed at Datadog (https://www.datadoghq.com/). Copyright 2020 Datadog, Inc.

# How to contribute a sample app

We invite every partner to contribute a sample app. If you have an app you use to demo Datadog to prospects or clients, adding it here makes it easy for others to find and run.

## Checklist

1. Create a new directory under `sandbox-apps/` named after your app (lowercase, words separated by `-`, e.g. `ecommerce-shoes`).
2. Copy the app's files into that directory. Don't add it as a git submodule, and don't preserve an external fork's git history — commit the files fresh.
3. Redact any real secrets. Provide a `.env.example` (or equivalent) with placeholder values in place of a real `.env` or credentials file, and confirm the app's own `.gitignore` excludes the real one.
4. Add a `README.md` describing what the app demonstrates and how to run it. [`sandbox-apps/swagbot/README.md`](sandbox-apps/swagbot/README.md) is a good reference.
5. Add an entry to the "Sandbox Applications" section of the root [README.md](README.md).

## What we look for

- Uses technologies that showcase Datadog integrations well.
- Supports a cross-product "platform" story rather than a single integration.
- Runs in containers (docker-compose, Kubernetes manifests, etc.), which makes it easier for others to adopt.
- Offers something the current apps don't — a new language, integration, architecture, or business use case.
- Could be an addition to an existing sandbox app rather than a new one, where that fits (e.g. a new microservice).
- Bonus: resembles what real Datadog customers actually run and monitor.
- Bonus: is interactive, which makes live demos more engaging.

If it's useful to you, it's likely useful to other partners too.

## Have an idea but don't want to write it yourself?

Open a [new issue](https://github.com/DataDog/dpn/issues/new) and tag it `new-sample-app-request`, or reach out to your Datadog Partner Solutions Architect (PSA).
