
> Unless explicitly stated otherwise all files in this repository are licensed under the Apache 2.0 License.
> This product includes software developed at Datadog (https://www.datadoghq.com/). Copyright 2020 Datadog, Inc.

# Partners Demo Sample Todo App Installation Guide

## Prerequisits:

(Installation time expectation: 10 minutes)

1. Git (download [here](https://git-scm.com/downloads))
2. Vagrant (download [here](https://www.vagrantup.com/downloads.html))
3. VirtualBox (download [here](https://www.virtualbox.org/wiki/Downloads))

## Setup:

(Time expectation: 10 minutes)

1. Open a shell/terminal
2. Clone this repo. (`git clone https://github.com/DataDog/dpn.git` or in Windows you can use the GUI)
3. In your shell, move to the directory that holds the environment configurations. (`cd dpn/sandbox-apps/sample-app-todo` or in powershell `cd .\dpn\sandbox-apps\sample-app-todo`)
4. Configure your `setup.env`, replacing all "REPLACE_ME" strings with your own values.
5. Run `vagrant up` (and then run the "y" confirmation if prompted).

And then it should all work out magically from there. It may take about 5-10 minutes for the whole thing to get running, so maybe go grab some coffee and come back. And if you see a bunch of warning- / error-looking messages in your terminal, don't panic, some warnings and errors are actually expected and totally benign. 

## Verification

Once you have control of the terminal again, you know the setup has finished. The last messages you see before that should look like `Creating * ... done.` At this point your app should be running and integrated nicely with your Datadog account. 

In order to verify that you have all the expected data coming into your Datadog account, visit your local app at http://localhost:8080/ in your browser and click around the different tabs at the top to interact with it and generate requests. You should then see data start to populate in your Datadog account in the following pages:

<details>
  <summary><a href="https://app.datadoghq.com/infrastructure" target="_blank">Infrastructure List</a></summary>
  
  ![Infrastructure List](https://github.com/DataDog/dpn/blob/master/sandbox-apps/sample-app-todo/static/images/infrastructure_list.png)
</details>

<details>
  <summary><a href="https://app.datadoghq.com/dashboard/lists/preset/2" target="_blank">Host Dashboard</a></summary>
  
  ![Host Dashboard](https://github.com/DataDog/dpn/blob/master/sandbox-apps/sample-app-todo/static/images/host_dashboard.png)
</details>

<details>
  <summary><a href="https://app.datadoghq.com/infrastructure/map?node_type=container" target="_blank">Container Map</a></summary>
  
  ![Container Map](https://github.com/DataDog/dpn/blob/master/sandbox-apps/sample-app-todo/static/images/container_map.png)
</details>

<details>
  <summary><a href="https://app.datadoghq.com/containers" target="_blank">Containers List</a></summary>
  
  ![Container List](https://github.com/DataDog/dpn/blob/master/sandbox-apps/sample-app-todo/static/images/container_list.png)
</details>

<details>
  <summary><a href="https://app.datadoghq.com/process" target="_blank">Processes List</a></summary>
  
  ![Process List](https://github.com/DataDog/dpn/blob/master/sandbox-apps/sample-app-todo/static/images/process_list.png)
</details>

<details>
  <summary><a href="https://app.datadoghq.com/apm/map?env=dpn-sandbox" target="_blank">Service Map</a></summary>
  
  (make sure to scope to the `env:dpn-sandbox`)

  ![Service Map](https://github.com/DataDog/dpn/blob/master/sandbox-apps/sample-app-todo/static/images/service_map.png)
</details>

<details>
  <summary><a href="https://app.datadoghq.com/apm/traces?env=dpn-sandbox" target="_blank">Trace Search</a></summary>
  
  (make sure to scope to the `env:dpn-sandbox`)

  ![Trace Search](https://github.com/DataDog/dpn/blob/master/sandbox-apps/sample-app-todo/static/images/trace_search.png)
</details>

<details>
  <summary><a href="https://app.datadoghq.com/logs" target="_blank">Log Explorer</a></summary>

  (you may have to click through the "getting started" flow before you see the logs)
  
  ![Log Explorer](https://github.com/DataDog/dpn/blob/master/sandbox-apps/sample-app-todo/static/images/log_explorer.png)
</details>

<details>
  <summary><a href="https://app.datadoghq.com/screen/integration/13/mongodb---overview" target="_blank">MongoDB Integration Dashboard</a></summary>

  ![Mongo Dashboard](https://github.com/DataDog/dpn/blob/master/sandbox-apps/sample-app-todo/static/images/mongo_dashboard.png)
</details>


## Shutting down

You can pause your virtual machine that runs your app with `vagrant halt`, or you can destroy it completely with `vagrant destroy`. Whenever you want to run it again, you can just `vagrant up --no-provision` again after that.

## Troubleshooting

If you want to access your vm to troubleshoot or modify anything, you can do so with `vagrant ssh`. Once you're in the VM, you can run `sudo docker ps` to see what containers are running.