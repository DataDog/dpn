
> Unless explicitly stated otherwise all files in this repository are licensed under the Apache 2.0 License.
> This product includes software developed at Datadog (https://www.datadoghq.com/). Copyright 2020 Datadog, Inc.

# **I want to make a sample app of my own, how do i do that?**

If you have your own apps that you like to use to demo Datadog to your prospects or clients, adding it as a sample app in your DPN repo can make it easy to deploy / destroy your app either locally or in AWS EC2 instances. Once you find an app you like to use for demoing, you can take these steps to add it as a sample app in your DPN repo:


## New Sandbox App Checklist

This checklist is a quick reference for all the steps you need to take. Further down you'll find more detailed explanations of each step. 

1. Create a new directory in `dpn/sandbox-apps/` that names your app
2. Add a `Vagrantfile`
3. Add a `<my-app-name>.tf` (replacing `<my-app-name>` with the actual name of the app)
4. Add a `setup.sh` provisioning script
5. Add a `setup.env` for environment variable definitions
6. Add a `data/` directory with a `data/.i.exist` file (can be empty) and any other special files you will need for your app


## Now the details:

### 1. Name your app, add a directory in `dpn/sandbox-apps/`

It’s best to make a descriptive name for your app that communicates what it does and (if necessary) how it differs from other existing similar sandbox apps. Names should be lower-case when possible, and each word delimited by a “-”. An example of a good name: “ecommerce-shoes”.

### 2. Vagrantfile

The Vagrantfile configures the app to be provisioned in a local VM. Its contents should match the following, except (A) you should edit the VM’s name, and (B) you can optionally increase the memory. It’s best if the app only requires 1GB, but if it requires more you can increase. For example, Java apps can sometimes requires 2 or 4GB.

```
# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure(2) do |config|
  config.vm.box = "bento/ubuntu-16.04"
  config.vm.network :forwarded_port, guest: 8000, host: 8000, auto_correct: true
  config.vm.synced_folder "./data", "/data", create: true

  config.vm.provider "virtualbox" do |vb|
    vb.name = "<my-app-name>"  # edit this
    vb.customize ["modifyvm", :id, "--memory", "1024"]  # edit if need more memory
  end

  config.vm.provision "shell", inline: "mkdir ~/data"
  config.vm.provision :file, source: './data', destination: '~/data'
  config.vm.provision :file, source: './setup.env', destination: '~/setup.env'
  config.vm.provision "shell", path: "./setup.sh", privileged: false

end
```

### 3. Terraform file (`<my-app-name>.tf`)

Much like the Vagrantfile, the terraform file configures the app to be provisioned in a remote EC2 instance.  Its contents should match the following, except (A) you should edit the app name, and (B) you can optionally uncomment and modify the size of the EC2 instance. The default size is t2.micro, which is sufficient for most projects. You can use more (Java often requires t2.medium), but bear in mind that larger instances will cost more to use. 

```
module "sandbox-apps" {
  resource_name = "<my-app-name>"
  source = "../_terraform/"
  # resource_size = "t2.micro" # only uncomment and change for unusually large/small projects. bigger == $$$
}

output "entry" {
  value = "${module.sandbox-apps.user}@${module.sandbox-apps.dns}"
}
```

### 4. setup.sh provisioning script

The `setup.sh` will provision your VM to run your app. All the commands you would run in a linux terminal to install an app manually on a new VM and enable/configure Datadog integrations are all going to be contained in this. You can place those commands inside the following template `setup.sh`

```
#!/bin/bash
# translate setup.env to unix-friendly just in case it came from dos
sudo sed -e "s/\r//g" setup.env > setup.env.new
sudo mv setup.env.new setup.env

# get env variables
. setup.env

TYPE=$(echo "$TYPE" | tr '[:upper:]' '[:lower:]')

echo "Provisioning!"

echo "apt-get updating"
sudo apt-get update
echo "installing curl, git..."
sudo apt-get -y install curl git

# this next bit sends an audit event to our DPN team so that they can see when a new sandbox is deployed
# this helps the DPN team understand what sandboxes are more valuable to our partners

DPN_STRING="puba793760ef4e28fab630a7f13eda9e213"
curl -X POST https://browser-http-intake.logs.datadoghq.com/v1/input/${DPN_STRING} \
-H "Content-Type: application/json" \
-d @- << EOF
{
	"message": "started provisioning a sandbox app", 
	"status": "info",
	"sandbox-app": "voting-app",
	"tag_defaults": "${TAG_DEFAULTS}",
	"hostname_base": "${HOSTNAME_BASE}",
	"step": "start",
	"type": "${TYPE}"
}
EOF


# Common content -- uncomment if you wish to use
#
# # Install docker
# echo "installing docker..."
# sudo curl -sSL https://get.docker.com/ | sh
# echo "installing docker-compose"
# sudo curl -L "https://github.com/docker/compose/releases/download/1.25.5/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
# sudo chmod +x /usr/local/bin/docker-compose
# sudo docker-compose --version

# # Example cloning an app's repo
echo "cloning app repo"
sudo git clone https://github.com/dockersamples/example-voting-app.git
cd example-voting-app

# # Example replacing a placeholder with a variable value
# # sudo sed -i.bak "s/PLACEHOLDER_PATTERN/REPLACE_WITH/g" [filepath/]filename
# sudo sed -i.bak "s/<DD_API_KEY>/${DD_API_KEY}/g" docker-compose.yml

# ...
# THIS IS WHERE YOUR CUSTOM CODE GOES
# ...

# this next bit sends another audit event to our DPN team so that they can see when a new sandbox completes deployment
# this helps them to proactively identify sandbox apps that do not complete their setup (and may have errors)

curl -X POST https://browser-http-intake.logs.datadoghq.com/v1/input/${DPN_STRING} \
-H "Content-Type: application/json" \
-d @- << EOF
{
	"message": "completed provisioning a sandbox app", 
	"status": "info",
	"sandbox-app": "voting-app",
	"tag_defaults": "${TAG_DEFAULTS}",
	"hostname_base": "${HOSTNAME_BASE}",
	"step": "end",
	"type": "${TYPE}"
}
EOF

echo "Operation complete!"
```

### 5. `setup.env` to contain the user-specific variable values

The setup.env is what someone uses to pass their own user-specific values into their sample app, such as API keys, hostname base strings, tags, etc. Its content will generally look like the following, but any value your setup.sh ends up needing should go into this. 

```
# Replace all REPLACE_ME strings with your own values

# Required vars
DD_API_KEY=REPLACE_ME
DD_APP_KEY=REPLACE_ME

HOSTNAME_BASE=REPLACE_ME
# HOSTNAME_BASE will become part of the hostname for your sandbox environment.
# it will help clarify what host is which in your Datadog account.
# example: HOSTNAME_BASE=jane.doe.laptop

TAG_DEFAULTS="REPLACE_ME REPLACE_ME"
# TAG_DEFAULTS defines what host tags are applied to the sandbox environment by default
# example: TAG_DEFAULTS="creator:jane.doe role:demo laptop:oct-2019"
```

### 6. a `data/` directory to contain any extra files that your app may need

You must have a `data/` directory in order for the Vagrant and Terraform modules to work, and you must have some file in that directory. For this reason, you should at least create a `data/.i.exist` file, even if that file is empty. 

The `data/` directory is a place you can put whole files and large pieces of data that your `setup.sh` can depend on. It can be a great way to simplify your `setup.sh` script. For example, if your `docker-compose.yml` ends up having a lot of content in it, it might be easier to add it to the `data/` directory and have your `setup.sh` replace values in it from the `setup.env` rather than having the `setup.sh` just contain all the contents of your `docker-compose.yml`. 
