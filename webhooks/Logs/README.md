# Logs related Webhooks
The Datadog API for Logs has several categories for general [Logs](https://docs.datadoghq.com/api/latest/logs/), [Archives](https://docs.datadoghq.com/api/latest/logs-archives/), [Indexes](https://docs.datadoghq.com/api/latest/logs-indexes/), [Metrics](https://docs.datadoghq.com/api/latest/logs-metrics/), [Pipelines](https://docs.datadoghq.com/api/latest/logs-pipelines/) and [Restriction queries](https://docs.datadoghq.com/api/latest/logs-restriction-queries/).

Several of the API calls requires using HTTP PUT rather than POST. Since Webhooks only use the POST method, we use utilize Synthetics Tests to perform the PUT method and trigger these Tests to run via Webhook as needed.

## Getting started
First complete the general Webhook Getting started.
Set up the [Synthetics trigger Webhook](webhooks/Synthetics).

## Synthetics API Test setup

### Manual setup
Create [Synthetic API HTTP Test](https://docs.datadoghq.com/synthetics/api_tests/http_tests). Use the URL listed below and the `synthetics-payload` JSON for the [request body](https://docs.datadoghq.com/synthetics/api_tests/http_tests/?tab=requestbody) docs.

### API Setup
Use the Synthetics API endpoint to create the Tests (TODO)

## Synthetics setup
| Synthetics Payload JSON                          | URL                                                               | Description                                                       |
|--------------------------------------------------|-------------------------------------------------------------------|-------------------------------------------------------------------|
| [synthetics-payload_disable_exclusion_filter.json](/webhooks/Logs/synthetics-payload_disable_exclusion_filter.json) | https://api.datadoghq.com/api/v1/logs/config/indexes/{index_name} | Disable an exclusion filter for Debug logs on a given index_name  |
| [synthetics-payload_enable_exclusion_filter.json](/webhooks/Logs/synthetics-payload_enable_exclusion_filter.json)  | https://api.datadoghq.com/api/v1/logs/config/indexes/{index_name} | Enable an exclusion filter for Debug logs on a given index_name   |
| [synthetics-payload_set_main_index_limit.json](/webhooks/Logs/synthetics-payload_set_main_index_limit.json)     | https://api.datadoghq.com/api/v1/logs/config/indexes/main         | Set a [daily quota](https://docs.datadoghq.com/logs/log_configuration/indexes#set-daily-quota) on the default "main" index                     |
|                                                  |                                                                   |                                                                   |
|                                                  |                                                                   |                                                                   |

## Resources
[Datadog Logs configuration](https://docs.datadoghq.com/logs/log_configuration/)
