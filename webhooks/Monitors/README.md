# Monitor related Webhooks
The Monitors API allows for various functionality. However there are some limitations to working with this API with Webhooks.

## Getting started
First complete the general Webhook Getting started.

## Considerations
The API endpoints used here require using a built-in variable for hostname within the URL.

Unmuting a host does not require a Payload.

## Webhook setup
| Payload JSON   | URL                                                    | Description                                       |
|----------------|--------------------------------------------------------|---------------------------------------------------|
| [mute_host.json](/webhooks/Monitors/mute_host.json) | https://api.datadoghq.com/api/v1/host/$HOSTNAME/mute   | Mute the host to prevent additional notifications |
| [NONE]         | https://api.datadoghq.com/api/v1/host/$HOSTNAME/unmute | Unmute host when the Alert has recovered          |
|                |                                                        |                                                   |
|                |                                                        |                                                   |

## Resources
[Alert Monitors API](https://docs.datadoghq.com/api/latest/monitors/)
[Hosts API](https://docs.datadoghq.com/api/latest/hosts/)