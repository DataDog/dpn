
> Unless explicitly stated otherwise all files in this repository are licensed under the Apache 2.0 License.
> This product includes software developed at Datadog (https://www.datadoghq.com/). Copyright 2020 Datadog, Inc.

# Partners Demo Ecommerce App Installation Guide

## Introduction

This sandbox application is an online shop for clothing called 'storedog'. It consists of multiple microservices and is a good way to learn or demo the infrastructure (host/containers), log management, application performance management and real user monitoring products of Datadog.

The application comes in two versions: "working" and "broken". This allows you to either just demo the Datadog products - using the 'working' version - or to demo the error-detection- and troubleshooting-process - using the 'broken' version.


## Prerequisites:

### Deploying Locally

To deploy locally, a virtual machine will be instantiated in which docker and the sandbox application itself is being installed.
Please note that the vm is running the Datadog APM agent and will therefore incur the cost for 1 infrastructure host and 1 APM host as long as the vm is running.

Expected installation time: 10 minutes

1. Clone or download this repo. (Git installation page (download [here](https://git-scm.com/downloads))
2. Vagrant (download [here](https://www.vagrantup.com/downloads.html))
3. VirtualBox (download [here](https://www.virtualbox.org/wiki/Downloads))

### Deploying in AWS

To deploy in AWS, a EC2 instance will be instantiated in which docker and the sandbox application itself is being installed.
Please be aware that this sandbox app will instantiate one EC2 t2.medium instance that will incur cost in your AWS account.

Expected installation time: 10-30 minutes, depending on your AWS account settings

1. Git (download [here](https://git-scm.com/downloads))
2. Terraform (installation and configuration guide [here](https://github.com/DataDog/dpn/tree/master/sandbox-apps/_terraform))


## Setup:
(Time expectation: 10 minutes)

1. Clone or download this repo. (Git installation page (download [here](https://git-scm.com/downloads))
2. In a terminal/shell, move to the directory that holds the environment configurations. (`cd dpn/sandbox-apps/ecommerce-webapp` or in powershell `cd .\dpn\sandbox-apps\ecommerce-webapp`)
3. Copy `setup.env.example` to `setup.env`.
4. Configure your `setup.env`, replacing all "REPLACE_ME" strings with your own values.
5. To deploy locally: Run `vagrant up` (and then enter the "y" confirmation if prompted). To deploy in AWS: Run the terraform `apply` command (and then enter the "yes" confirmation when prompted)

And then it should all work out magically from there. It will take about 10 minutes for the whole thing to get running, so maybe go grab some coffee and come back. And if you see a bunch of warning- / error-looking messages in your terminal, don't panic, some warnings and errors are actually expected and totally benign.

## Verification

Once you have control of the terminal again, you know the setup has finished. The last messages you see before that should look like `Operation complete!` or `Creating * ... done.` At this point your app should be running and integrated nicely with your Datadog account.

In order to verify that you have all the expected data coming into your Datadog account, visit your local app at http://localhost:8000/ in your browser and select a few buttons. Then go to http://localhost:8080/ and do the same thing. If you deployed in AWS, your terminal will tell you the server IP addresses, so you can instead go to http://that_ip:8000/ and http://that_ip:8080/ instead.

Remember that by choosing the port number, you can either browse the 'working' version (http://localhost:8000/):
![working version](https://github.com/DataDog/dpn/blob/master/sandbox-apps/ecommerce-webapp/static/images/storedog_working.jpg)

and the 'broken' version (http://localhost:8080/ )
![broken version](https://github.com/DataDog/dpn/blob/master/sandbox-apps/ecommerce-webapp/static/images/storedog_broken.jpg)


At this point, you should then start to data start to populate in your Datadog account in the following pages:

(Verification photos and links forthecoming)e
<details>
  <summary><a href="https://app.datadoghq.com/infrastructure" target="_blank">Infrastructure List</a></summary>

  ![Infrastructure List](https://github.com/DataDog/dpn/blob/master/sandbox-apps/ecommerce-webapp/static/images/infrastructure_list.jpg)
</details>

<details>
  <summary><a href="https://app.datadoghq.com/infrastructure/map?node_type=container" target="_blank">Container Map</a></summary>

  ![Container Map](https://github.com/DataDog/dpn/blob/master/sandbox-apps/ecommerce-webapp/static/images/container_map.jpg)
</details>

<details>
  <summary><a href="https://app.datadoghq.com/containers" target="_blank">Containers List</a></summary>

  ![Container List](https://github.com/DataDog/dpn/blob/master/sandbox-apps/ecommerce-webapp/static/images/container_list.jpg)
</details>

<details>
  <summary><a href="https://app.datadoghq.com/process" target="_blank">Processes List</a></summary>

  ![Process List](https://github.com/DataDog/dpn/blob/master/sandbox-apps/ecommerce-webapp/static/images/processes_list.jpg)
</details>

<details>
  <summary><a href="https://app.datadoghq.com/apm/map?env=dpn-sandbox" target="_blank">Service Map</a></summary>

  (make sure to scope to the relevant "env")

  ![Service Map](https://github.com/DataDog/dpn/blob/master/sandbox-apps/ecommerce-webapp/static/images/service_map.jpg)
</details>

<details>
  <summary><a href="https://app.datadoghq.com/apm/traces?env=dpn-sandbox" target="_blank">Trace Search</a></summary>

  (make sure to scope to the relevant "env")

  ![Trace Search](https://github.com/DataDog/dpn/blob/master/sandbox-apps/ecommerce-webapp/static/images/trace_search.jpg)
</details>

<details>
  <summary><a href="https://app.datadoghq.com/logs" target="_blank">Log Explorer</a></summary>

  (you may have to click through the "getting started" flow before you see the logs, make sure to filter out the service "agent".)

  ![Log Explorer](https://github.com/DataDog/dpn/blob/master/sandbox-apps/ecommerce-webapp/static/images/log_explorer.jpg)
</details>

<details>
  <summary><a href="https://app.datadoghq.com/rum" target="_blank">Real User Monitoring</a></summary>

  You will find "storedog-XXX" (where XXX is the name of the host you defined in your setup.env file) in the list of RUM Applications.

  ![RUM Applications](https://github.com/DataDog/dpn/blob/master/sandbox-apps/ecommerce-webapp/static/images/rum_applications.jpg)

  Drill-down into your RUM Application to see performance details on the application

  ![RUM Details](https://github.com/DataDog/dpn/blob/master/sandbox-apps/ecommerce-webapp/static/images/rum_applications.jpg)

</details>

## Shutting down

You can pause your virtual machine that runs your app with `vagrant halt`, or you can destroy it completely with `vagrant destroy`. Whenever you want to run it again, you can just `vagrant up --no-provision` again after that.

For AWS deployments, you can tear down your application with the terraform `destroy` command, and rebuild again with the `apply` command.

## Troubleshooting

If you want to access your vm to troubleshoot or modify anything, for local deployments you can do so with `vagrant ssh`. Once you're in the VM, you can run `sudo docker ps` to see what containers are running.

For deployments in AWS, you can ssh to your instance with `ssh -i /path/to/<my_key_file>.pem ubuntu@<my_ip>` and from there you can run `sudo docker ps` to see what containers are running.
