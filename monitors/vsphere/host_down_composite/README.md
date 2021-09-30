## vSphere Host Down Composite Monitor

### Monitor Description
- The purpose of this monitor is to avoid false alerts for HOST DOWN situations in a vSphere environment.  To do this, we created 2 normal monitors, one to monitor the system uptime of HOSTS (ESXi) via the vSphere integration which is collected by an agent based integration that polls the vCenter server API.  The second one is to ensure that the agent based collector is still receiving metrics from the API itself and that the agent integration is functioning as expected.
- We then created the composite alert so that if a HOST or HOSTS stop reporting uptime it will only trigger if the collector is running and collecting metrics as expected.  The composite alert becomes the means of triggering HOST DOWN notifications.
- The vsphere_collector_no_metrics monitor will trigger notifications by vCenter server when Datadog sees a NO DATA condition.

#### vsphere_host_down
- Monitors vSphere HOSTs and is part of composite monitor to avoid false alerts when/if vSphere collector (on Datadog agent) or API (on vCenter server) is down.

#### vsphere_collector_no_metrics
- Monitors metrics collection on vSphere collector (running on Datadog agent) and notifies if metrics stop coming in from the vCenter server.  This is the second part of the vSphere composite monitor.

#### vsphere_composite_alert
- Composite monitor that will alert on vSphere HOST DOWN when a HOST uptime metric stops coming in BUT all other metrics are still being seen by the vSphere collector (running on Datadog agent).  This avoids numerous host down alerts when the vSphere collector is not seeing metrics.  
- **PLEASE NOTE** - to import this monitor you will need to first import the two monitors above that make it up and insert their monitor IDs into the json as noted in the alert itself.
