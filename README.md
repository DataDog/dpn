
> Unless explicitly stated otherwise all files in this repository are licensed under the Apache 2.0 License.
> This product includes software developed at Datadog (https://www.datadoghq.com/). Copyright 2020 Datadog, Inc.

# dpn
This repo is a collection of resources for authorized members of the Datadog Partner Network, and is intended to help partners show and deliver the value of the Datadog platform.

In this repo, you will find things like:

  - Sandbox applications you can easily deploy to show how to monitor modern enironments and services
  - Sample dashboards and monitors that demonstrate best-practices or are useful for specific integrations and use-cases
  - Example runbooks for how to conduct common investigations
  - Configurations of different products that are frequently helpful
  - Automation scripts and tooling that a partner would frequently find useful

Please consider [contributing](#Contributing-and-Feedback) to this repo, since it'll get much more useful with the input of our partners!


# Table of Contents

## Sandbox Applications

1. [Sample-App-Todo](https://github.com/DataDog/dpn/tree/master/sandbox-apps/sample-app-todo) - A simple node todo list app with the MongoDB integration, tracing, and logs pre-configured.
2. [Voting-App](https://github.com/DataDog/dpn/tree/master/sandbox-apps/voting-app) - A containerized app that hosts a voting session and posts the results to another endpoint. Uses Python, .NET, NodeJS, Postgresql, Redis. Includes APM tracing, log collection, and infrastructure monitoring. 
3. [Ecommerce-Webapp](https://github.com/DataDog/dpn/tree/master/sandbox-apps/ecommerce-webapp) - A containerized application that hosts an entire ecommerce web application. You can run both a working as well as a "broken" version of the application. Includes APM tracing, Real User Monitoring, log collection and infrastructure monitoring.

## Dashboards
(Forthcoming)

## Monitors
(Forthcoming)

## Notebooks & Runbooks
(Forthcoming)

## Product Configurations
(Forthcoming)

## Docs
A collection of docs to get off to a good start with Datadog

1. [Datadog on Minikube](./docs/minikube.md) - A guide to configure Datadog agent on Minikube

## Automation Tooling

### Scripts
A collection of resources dedicated to deployments that happen in Azure.

1. [Windows Secret Fetcher (Azure KeyVault)](./scripts/secrets-exe) - A guide on how to create an Azure KeyVault Secrets fetcher for use with [Datadog Secrets Management](https://docs.datadoghq.com/agent/guide/secrets-management/?tab=windows)

### Utils
A collection of compiled resources that can be used in addition to the Datadog agent

1. [AWS Secret Fetcher (AWS Secret Manager)](./utils/go-aws-secrets-manager) - A guide on how to create an AWS secrets fetcher for use with [Datadog Secrets Management on Linux and Windows](https://docs.datadoghq.com/agent/guide/secrets-management/?tab=linux)

# Contributing and Feedback
Thank you for contributing! If you wish to contribute an application, dashboard, or other resources to this repo, or if you wish to share feedback on how we can make it better, please email charlie@datadoghq.com. 
