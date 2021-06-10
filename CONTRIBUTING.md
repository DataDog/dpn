
> Unless explicitly stated otherwise all files in this repository are licensed under the Apache 2.0 License.
> This product includes software developed at Datadog (https://www.datadoghq.com/). Copyright 2020 Datadog, Inc.

## How to contribute

First off: thank you so much for contributing!


### **Bugs**

* **If you found something that you think may be a security vulnerability, do not open a GitHub issue** and instead contact security@datadoghq.com (and quickly!)

* For all other things that seem like bugs or problems, please do a quick check first to see if someone has already opened an issue for it under [Issues](https://github.com/DataDog/dpn/issues)

* If no existing issues seem relevant, please [open a new one](https://github.com/DataDog/dpn/issues/new). When you open issues, please include a clear title and description and as much relevant info as possible.  Pasting in errors is great, and any info specific to your environment is very helpful. And **Please be careful to redact any sensitive data like API keys or credentials!**

* Please have patience: This repo is a "best effort" project. It is owned by employees at Datadog, but they're busy people! And the owners will change over time. The more info you can provide, the faster they may be able to help. 

* Please do not request help from support@datadoghq.com for problems that appear specific to the resources in this repo. This repo is not owned by the Datadog support team. 


### **Did you find a bug fix yourself?**

* Great! Please open a new GitHub [pull request](https://github.com/DataDog/dpn/pulls) with the fix.

* Ensure the PR description clearly describes the problem and solution. Include the relevant issue number if applicable.


### **Do you want to add a new sample app of your own to your repo?**

Here's a [separate guide for how to add your own sample apps](https://github.com/DataDog/dpn/blob/master/CONTRIBUTING-sample-apps.md).


### **Do you have a new sample app to contribute?**

Great! Please [open a PR](https://github.com/DataDog/dpn/pulls) to add it! 

Here are a few things we like to look for in new sample apps:

* Does it use lots of technologies that can be used to showcase Datadog integrations?
* Can we use lots of products with it to demonstrate a comprehensive “platform” approach to monitoring?
* Can it be run in containers? Does a docker-compose or a terraform form script exist for it? (If yes, that'll make adding a sample app for it easier)
* Would the new sample app offer something that the current suite of sample apps don't have? (A new language, a new integration, a new architecture, a new business sector or valuable real-life use-case, etc.)
* If you're writing the sample app yourself, consider if it could be an addition to an existing sandbox app - e.g. a new microservice. 
* (Bonus points) Is the app similar or comparable to apps that real-life Datadog users/prospects will be monitoring?
* (Bonus points) Can the app be interactive? (Helps to make demonstrations of the product more engaging)

That said, chances are that if the sample app would be useful to you, it'll be useful to other partners too, so if it's something you'd use and value, please feel free to make a PR!

When you have [created your own sample app in your repo](https://github.com/DataDog/dpn/blob/master/CONTRIBUTING-sample-apps.md) and are ready to create a PR for it, here are some extra steps you will want to take:

1. Redact any sensitive strings like API keys, etc.
2. Change your `setup.env` file to a `setup.env.example` file with all the values replaced with "REPLACE_ME"
3. Add a README.md file to your sample app's directory to help other partners understand what the new app is good for and how to use it. [Here's an example of what a README.md may look like.](https://github.com/DataDog/dpn/blob/master/sandbox-apps/voting-app/README.md)


### **Do you have a new sample app that you want added but that you don't want to write the code for?**

Cool! Please create a [new issue](https://github.com/DataDog/dpn/issues/new) and tag it with "new-sample-app-request"


### **Do you have a dashboard, monitor, or other resource that you find useful and would like to add as a resource for others?**

Great! Please [open a PR](https://github.com/DataDog/dpn/pulls) to add it! Please also provide a screenshot of your dashboard, monitor, or other resource in the PR and a thorough description of what it is and why it's valuable. 
We are also always looking for dashboards, monitors, etc. that are created through the API / Terraform. 

:heart: Thanks tons! :heart:

The Datadog Partners' Network Team
