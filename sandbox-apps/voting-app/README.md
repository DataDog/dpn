
> Unless explicitly stated otherwise all files in this repository are licensed under the Apache 2.0 License.
> This product includes software developed at Datadog (https://www.datadoghq.com/). Copyright 2020 Datadog, Inc.

# Partners Demo Sample Voting App Installation Guide

## Prerequisits:

### Deploying Locally

(Installation time expectation: 10 minutes)

1. Clone or download this repo. (Git installation page (download [here](https://git-scm.com/downloads))
2. Vagrant (download [here](https://www.vagrantup.com/downloads.html))
3. VirtualBox (download [here](https://www.virtualbox.org/wiki/Downloads))

### Deploying in AWS

(Installation time expectation: 10-30 minutes, depending on your AWS account settings)

1. Git (download [here](https://git-scm.com/downloads))
2. Terraform (installation and configuration guide [here](https://github.com/DataDog/dpn/tree/master/sandbox-apps/_terraform))

## Setup:

(Time expectation: 10 minutes)

1. Clone or download this repo. (Git installation page (download [here](https://git-scm.com/downloads))
2. In a terminal/shell, move to the directory that holds the environment configurations. (`cd dpn/sandbox-apps/voting-app` or in powershell `cd .\dpn\sandbox-apps\voting-app`)
3. Configure your `setup.env`, replacing all "REPLACE_ME" strings with your own values.
4. To deploy locally: Run `vagrant up` (and then enter the "y" confirmation if prompted). To deploy in AWS: Run the terraform `apply` command (and then enter the "yes" confirmation when prompted)

And then it should all work out magically from there. It may take about 5-10 minutes for the whole thing to get running, so maybe go grab some coffee and come back. And if you see a bunch of warning- / error-looking messages in your terminal, don't panic, some warnings and errors are actually expected and totally benign. 

## Verification

Once you have control of the terminal again, you know the setup has finished. The last messages you see before that should look like `Operation complete!` or `Creating * ... done.` At this point your app should be running and integrated nicely with your Datadog account. 

In order to verify that you have all the expected data coming into your Datadog account, visit your local app at http://localhost:8000/ in your browser and make a few votes (new votes overwrite previous ones). Then go to http://localhost:8080/ and wait a bit to watch the voting results refresh. If you deployed in AWS, your terminal will tell you the server IP addresses, so you can instead go to http://that_ip:8000/ and http://that_ip:8080/ instead.

At this point, you should then start to data start to populate in your Datadog account in the following pages:

<details>
  <summary><a href="https://app.datadoghq.com/infrastructure" target="_blank">Infrastructure List</a></summary>
  
  ![Infrastructure List](https://github.com/DataDog/dpn/blob/master/sandbox-apps/voting-app/static/images/infrastructure_list.jpg)
</details>

<details>
  <summary><a href="https://app.datadoghq.com/dashboard/lists/preset/2" target="_blank">Host Dashboard</a></summary>
  
  ![Host Dashboard](https://github.com/DataDog/dpn/blob/master/sandbox-apps/voting-app/static/images/host_dashboard.jpg)
</details>

<details>
  <summary><a href="https://app.datadoghq.com/infrastructure/map?node_type=container" target="_blank">Container Map</a></summary>
  
  ![Container Map](https://github.com/DataDog/dpn/blob/master/sandbox-apps/voting-app/static/images/container_map.jpg)
</details>

<details>
  <summary><a href="https://app.datadoghq.com/containers" target="_blank">Containers List</a></summary>
  
  ![Container List](https://github.com/DataDog/dpn/blob/master/sandbox-apps/voting-app/static/images/container_list.jpg)
</details>

<details>
  <summary><a href="https://app.datadoghq.com/process" target="_blank">Processes List</a></summary>
  
  ![Process List](https://github.com/DataDog/dpn/blob/master/sandbox-apps/voting-app/static/images/process_list.jpg)
</details>

<details>
  <summary><a href="https://app.datadoghq.com/apm/map?env=dpn-sandbox" target="_blank">Service Map</a></summary>
  
  (make sure to scope to the relevant "env")

  ![Service Map](https://github.com/DataDog/dpn/blob/master/sandbox-apps/voting-app/static/images/service_map.jpg)
</details>

<details>
  <summary><a href="https://app.datadoghq.com/apm/traces?env=dpn-sandbox" target="_blank">Trace Search</a></summary>
  
  (make sure to scope to the relevant "env")

  ![Trace Search](https://github.com/DataDog/dpn/blob/master/sandbox-apps/voting-app/static/images/trace_search.jpg)
</details>

<details>
  <summary><a href="https://app.datadoghq.com/logs" target="_blank">Log Explorer</a></summary>

  (you may have to click through the "getting started" flow before you see the logs)
  
  ![Log Explorer](https://github.com/DataDog/dpn/blob/master/sandbox-apps/voting-app/static/images/log_explorer.jpg)
</details>

<details>
  <summary><a href="https://app.datadoghq.com/screen/integration/256/jvm-metrics" target="_blank">JVM Integration Dashboard</a></summary>

  ![JVM Dashboard](https://github.com/DataDog/dpn/blob/master/sandbox-apps/voting-app/static/images/jvm_dashboard.jpg)
</details>

## Shutting down

You can pause your virtual machine that runs your app with `vagrant halt`, or you can destroy it completely with `vagrant destroy`. Whenever you want to run it again, you can just `vagrant up` again after that.

For AWS deployments, you can tear down your application with the terraform `destroy` command, and rebuild again with the `apply` command. 

## Troubleshooting

If you want to access your vm to troubleshoot or modify anything, for local deployments you can do so with `vagrant ssh`. Once you're in the VM, you can run `sudo docker ps` to see what containers are running.

For deployments in AWS, you can ssh to your instance with `ssh -i /path/to/<my_key_file>.pem ubuntu@<my_ip>` and from there you can run `sudo docker ps` to see what containers are running.