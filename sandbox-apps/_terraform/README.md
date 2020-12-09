
> Unless explicitly stated otherwise all files in this repository are licensed under the Apache 2.0 License.
> This product includes software developed at Datadog (https://www.datadoghq.com/). Copyright 2020 Datadog, Inc.

# Running Sandbox Apps with Cloud Providers

You can optionally provision your sandbox apps to run on EC2 instances in your AWS account, instead of running them locally. This can have several benefits, including:

- sandbox apps don't have to compete with resources on a machine you regularly use for work
- you can just leave a sandbox app running and have it when you need it without needing to reprovision it ahead of time
- you can expose sandbox apps so that they can be used by the people you are demoing them to, which could provide for more interactive demos.

This document outlines the steps to install terraform for provisioning sandbox apps in AWS. Once installed and configured, you can launch sandbox apps in your AWS account with a simple `terraform apply` command, much like you can launch them locally with `vagrant up`.

This repo currently only supports provisioning sandbox apps in AWS, but we plan to add support for all the major cloud providers as well as some options for private datacenters in the future.

## Install Terraform

Installing terraform is easy -- you just [download the binary file appropriate for your operating system](https://www.terraform.io/downloads.html), unzip it, and then move it to your system's "path" folder.

If you're on Mac / Linux, to find where to move the unzipped binary, open a terminal and run `echo $PATH`. Pick one of the directory outputs from that command, and move your unzipped file to it. For example, if your PATH includes `/usr/local/bin/`, and if your unzipped file is still in your downloads folder, you can move the binary to your PATH with `mv ~/Downloads/terraform /usr/local/bin/`.

If you're on Windows, you can find out what your `%path%` is by going to `Control Panel` -> `System` -> `System settings` -> `Environment Variables` and scroll down until you find `PATH`. From there, you can either move the unzipped `terraform` binary in a folder included in your `PATH`, or you can edit your `PATH` value to include the folder that holds it (e.g, you could make your own `C:\Programfile\terraform\` or something if you wanted to and add that.)

Once the unzipped `terraform` binary is in your path, it's installed!

## Configure Authentication with your Cloud Provider

You'll need to configure your terraform to be able to authenticate with your AWS account. You could theoretically just create AWS credentials, store them in `~/.aws/credentials` (or `%UserProfile%\\.aws\\credentials` for Windows) and call it done, but we don't recommend that -- there are a number of important security practices that you would be skipping there. So we're going to recommend taking a few additional steps to make sure your terraform can authenticate safely with your AWS account. 

### Step 1: Create AWS credentials

To allow terraform to talk to your AWS account, you'll want to go to your iam user page and create a secret Access Key. The link to this page in your aws account will look like this: 
`https://console.aws.amazon.com/iam/home?#/users/<YOUR_AWS_USER_NAME>?section=security_credentials`

If you _did_ want to take the easy and not-secure (and not-recommended) route, you would then create an `~/.aws/credentials` file (or `%UserProfile%\\.aws\\credentials` for Windows) that would contain the contents of your Access Key like so:

```
[default]
aws_access_key_id=REPLACE_ME
aws_secret_access_key=REPLACE_ME
```

### Step 2: Encrypt disk-stored credentials

We recommend installing a tool called `aws-vault` to make sure you can have your Access Key stored in an encrypted and secure way. To do this, take these steps:

1. [Install `aws-vault`](https://github.com/99designs/aws-vault#installing) following the instructions for your operating system.
2. Run `aws-vault add default` (creates a default credentials profile)
3. When prompted, paste in your AWS Access Key ID and Secret Key that you created in `Step 1`.

Good work -- now you've encrypted your credentials so that they're safe from leaking / someone stealing them from your machine! Note, now that you're using aws-vault, you're also able to use Multi-Factor Authentication when you interact with your AWS account, which your organization may require or encourage (and we encourage it!)

### Step 3: Use role delegation

You'll also want to make sure you limit what kinds of actions terraform can take in your account. You can do this by [creating a role](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create.html) for your terraform, or using a pre-existing role that has appropriate limits on what actions can be taken in your AWS account. You may not have access to create a role, in which case you may need to reach out to an admin in your AWS account and describe to them what your goals are. Or you may have a role handy that you're already using that would be safe to use for your DPN sandbox applications. 

Once you have a role that you can use, configure your `~/.aws/config` (or `%UserProfile%\\.aws\\config` for Windows) to use that role by adding this content:

```
[profile dpn-sandbox]
role_arn=arn:aws:iam::AWS_ACCOUNT_NUMBER:role/ROLE_NAME
source_profile=default
role_session_name=AWS_USER_NAME
# mfa_serial=arn:aws:iam::AWS_ACCOUNT_NUMBER:mfa/AWS_USER_NAME  # if you are using MFA
```

Congratulations -- now you've configured your environment to use `aws-vault` to authenticate `terraform` with your AWS account. To use it, when you want to run terraform commands, you'll nest them inside an `aws-vault` command like so: `aws-vault exec dpn-sandbox -- terraform get`. But don't worry, we'll provide info on how to make that shorter and sweeter in the "Tips and Tricks" section. 

## Configure Authentication with your Provisioned Servers

At this point you've successfully configured your terraform to authenticate with your AWS account, but there are some additional setup steps you'll need to take before you can have terraform spin up a sandbox app. These steps include:

1. Create a VPC and subnet for your EC2 instances
2. Create an SSH secret key pair
3. Configure a security group for your DPN sandbox apps that allows access from your computer

### Programmatical setup

All of these steps can be completed programmatically with the terraform module located in `_terraform/_configure/`. Go to that directory, copy the `_terraform/_configure/variables.tf.example` to `_terraform/_configure/variables.tf`, and replace all the necessary "REPLACE_ME" values (the file comments will tell you which are necessary). Finally, run the following commands:

1. Run `terraform init` or, if you configured `aws-vault` according to the instructions of this doc, `aws-vault exec dpn-sandbox -- terraform init`
2. Run `terraform get` or, if you configured `aws-vault` according to the instructions of this doc, `aws-vault exec dpn-sandbox -- terraform get`
3. Run `terraform plan` or, if you configured `aws-vault` according to the instructions of this doc, `aws-vault exec dpn-sandbox -- terraform plan` (technically this is optional, but it's good practice to review what changes will take place before you run the next command)
4. Run `terraform apply` or, if you configured `aws-vault` according to the instructions of this doc, `aws-vault exec dpn-sandbox -- terraform apply`

Applying this module will create those resources and will write their names and IDs to a `_terraform/_configure/configured.tfvars` file that your Sandbox Apps will use when you provision them. 

If you wish to destroy the resources that this module creates, you can easily do so with `terraform destroy` (include the `aws-vault` preface if relevant). But you should not attempt to destroy these resources if you have sandbox apps still running that depend on them (the destroy attempt will fail).

This programmatical configuration option is available for Unix-based operating systems and current versions of Windows 10. It relies on the availability of OpenSSH which is enabled by default on unix-based OSes and recent versions of Windows 10. For all these OS types, the use of the programmatical configuration option is the same, but Windows 10 users should make sure to set the variable in `_terraform/_configure/variables.tf` called `my_os_is_windows` to `true` (by default it is `false`). 

### Manual setup

Alternatively, if you already have these AWS resources listed above and wish to use them for your DPN sandbox, you can instead copy the `_terraform/variables.tf.example` to `_terraform/variables.tf` and edit that file with the names and IDs of your AWS resources.

## Using terraform

Congratulations, you're now ready to use terraform to spin up sandbox apps from this repo! To spin up an app, take these steps:

1. Go to the repo of one of your sandbox apps (typically `dpn/sandbox-apps/APPNAME`)
2. Configure the `setup.env` in that repo
3. Run `terraform init` or, if you configured `aws-vault` according to the instructions of this doc, `aws-vault exec dpn-sandbox -- terraform init`
4. Run `terraform get` or, if you configured `aws-vault` according to the instructions of this doc, `aws-vault exec dpn-sandbox -- terraform get`
5. Run `terraform plan` or, if you configured `aws-vault` according to the instructions of this doc, `aws-vault exec dpn-sandbox -- terraform plan` (this is optional, but good practice, it gives details on what will be changed with the next command)
6. Run `terraform apply` or, if you configured `aws-vault` according to the instructions of this doc, `aws-vault exec dpn-sandbox -- terraform apply`

Provisioning a new sandbox app can take 5-10 minutes, so after confirming the provision with "yes", feel free to grab coffee. Once it's finished, your terminal will tell you the name and ip that you can use to connect to the EC2 instance, if you need to connect to it in the future. If you have configured your security group to allow HTTP requests from your laptop, you can access the sandbox app at http://EC2_IP_ADDRESS:80 and any secondary pages at http://EC2_IP_ADDRESS:8000. Making requests on those pages will generate data in your Datadog account, which is helpful for demoing purposes. If you lose the IP address at some point, you can find it again by running `aws-vault exec dpn-sandbox -- terraform show | grep "public_ip"`.

If you need to connect to the EC2 instance that you created via terraform, you can do so with your ssh app of choice, so long as you connect with...

1. the username that was printed in your terminal after the terraform command completed (typically "ubuntu")
2. the ip address for the EC2 that was printed in your terminal after the terraform command completed.
3. the ssh private key that you configured terraform to use to ssh to your EC2 instances. (if you used the programmatical configuration approach, the private key will be at `~/.ssh/dpn-sandbox.pem` (or `$home\\.ssh\\dpn-sandbox.pem` for Windows)

If you're connecting from a mac / linux terminal, the ssh command looks like this: `ssh -i ~/.ssh/<my_key_file>.pem <user>@<the_public_ip>`. If you're on a Windows machine, [you may need to follow this guide to start your sshd server](https://www.pugetsystems.com/labs/hpc/How-To-Use-SSH-Client-and-Server-on-Windows-10-1470/), and the you can use that same ssh command. 

## Tips and Tricks

#### Alias your terraform command to something short and sweet

If you installed `aws-vault` for more secure authentication from terraform to your AWS account (this is recommended!) then for every terraform command you make you have to nest it in a much longer `aws-vault exec PROFILENAME -- ` command. That's sort of annoying. Fortunately, in mac/linux you can alias commands of this sort to something much shorter by editing your `~/.bashrc` or `~/.bash_profile` file and adding the following content (or similar):

`alias tf='aws-vault exec demo-account-admin -- terraform'`

Then you can `source ~/.bashrc` and from then on, instead of writing the whole long command, you can just write `tf apply` every time you want to run `terraform apply` with `aws-vault`.

A similar approach should be feasible with Windows 10, and [this link may provide some guidance on how to navigate its setup](https://stackoverflow.com/questions/20530996/aliases-in-windows-command-prompt). 

#### Alias your ssh connections

Along the same lines, if you frequently ssh to your EC2 instances that run sandbox apps, you can alias that long ssh command where you specify the private key file to use in your `~/.bashrc` or `~/.bash_profile` as follows:

`alias ssh_dpn='ssh -i ~/.ssh/<my_key_file>.pem'`

Then after running `source ~/.bashrc` you can run `ssh_dpn <user>@<the_public_ip>` to ssh into your EC2 instance. 
