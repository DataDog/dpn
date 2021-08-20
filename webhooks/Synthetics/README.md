# Synthetics related webhooks
These examples use the [Synthetics API endpoint(https://docs.datadoghq.com/synthetics/)]. Running a Synthetics Test from Webhook allows for more flexibility when working with API calls. Synthetics Test for example, can do other HTTP methods besides POST.

## Getting started
First complete the general Webhook Getting started.

You will also need to create [Synthetics Global Variables(https://docs.datadoghq.com/synthetics/settings/?tab=specifyvalue#global-variables)] for your Datadog API and Application keys.
 - DD_API_KEY
 - DD_APPLICATION_KEY

These will need to be added to each Test as Request-Headers under Advanced Options > [Request Options](https://docs.datadoghq.com/synthetics/api_tests/http_tests?tab=requestoptions). You will also need to add the following Header:
 - Content-Type `application/json`

## Examples
A table of example with name (linking to folder) and description