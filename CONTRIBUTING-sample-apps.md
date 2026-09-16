
> Unless explicitly stated otherwise all files in this repository are licensed under the Apache 2.0 License.
> This product includes software developed at Datadog (https://www.datadoghq.com/). Copyright 2020 Datadog, Inc.

# **I want to make a sample app of my own, how do I do that?**

If you have your own app that you like to use to demo Datadog to your prospects or clients, adding it here makes it easy for other partners to find and run it too.

## New Sandbox App Checklist

1. Decide where it belongs — see "In this repo, or its own repo?" below.
2. Create a new directory in `dpn/sandbox-apps/` named after your app (lower-case, words separated by `-`, e.g. `ecommerce-shoes`).
3. Copy your app's files into that directory. Don't add it as a git submodule and don't preserve an external fork's git history — just the files, committed fresh here.
4. Redact any real secrets. If your app needs config values (API keys, passwords, etc.), provide a `.env.example` (or equivalent) with placeholder values instead of a real `.env`/credentials file, and make sure your app's own `.gitignore` excludes the real one.
5. Add a `README.md` in your app's directory explaining what it demonstrates and how to run it. [`sandbox-apps/swagbot/README.md`](sandbox-apps/swagbot/README.md) is a good example to follow.
6. Add an entry for your app to the "Sandbox Applications" section of the root [README.md](README.md).

## In this repo, or its own repo?

Most sample apps live directly under `sandbox-apps/`. But if your app is going to be actively maintained on its own (its own CI, its own release cadence, its own contributors), consider giving it a dedicated `DataDog/<app-name>` repo instead, and just linking to it from this repo's `README.md` — that's how apps like Bank of Anthos, Storedog, and the TSRE microservices demo are handled. When in doubt, start it here; it's easy to split out into its own repo later if it grows.

## What we look for in new sample apps

* Does it use technologies that showcase Datadog integrations well?
* Can it demonstrate a comprehensive "platform" story across multiple products?
* Can it run in containers (docker-compose, Kubernetes manifests, etc.)? That makes it much easier for other partners to pick up.
* Does it offer something the current apps don't (a new language, integration, architecture, or business use-case)?
* Could it be an addition to an existing sandbox app instead of a whole new one (e.g. a new microservice)?
* (Bonus) Is it similar to what real Datadog customers actually run and monitor?
* (Bonus) Is it interactive, to make live demos more engaging?

If it'd be useful to you, it's probably useful to other partners too — open a PR!

## Don't want to write the code yourself?

Open a [new issue](https://github.com/DataDog/dpn/issues/new) and tag it `new-sample-app-request`.
