# Go Secrets Manager

This tool allows you to get secrets from AWS secrets manager on any EC2 instance configured with the right role. It's lightweight, fast and easy to use (no config file). This documentation comes with all the necessary information to use it with the Datadog agent. For more information on this feature, you can refer to this documentation:

[Secrets Management](https://docs.datadoghq.com/agent/guide/secrets-management/?tab=linux)

## AWS

> Your EC2 instances need to be in the same region than the secrets you’re looking for, otherwise copy the secrets to the appropriate region.

### Configure IAM

EC2 instances targeted to use this feature first need a role to be able to read from the Secrets Manager. Let’s start with a simple role:

![fig1](https://p-qkfgo2.t2.n0.cdn.getcloudapp.com/items/RBuEKxqj/c52fce5b-7bc1-4348-a7ff-51de0f370eff.jpg?source=viewer&v=560a4445f0b616c3f7b0657901795e77)

<img src="https://a.cl.ly/RBuEKxqj"
     alt="test"
     style="float: left; margin-right: 10px;" />

And its associated policy:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": "secretsmanager:GetSecretValue",
            "Resource": "*"
        }
    ]
}
```

You need to associate this role to the EC2 instance:

![fig2](https://p-qkfgo2.t2.n0.cdn.getcloudapp.com/items/E0uK21rd/7be2f461-babc-4c10-a2cb-92a38e88e5cc.jpg?source=viewer&v=094cc30340b204b313cc64247e85e892)

### Setup

In order to be able to use this tool, you need first to compile it. We provide you with quick instructions if you are already familiar with Go, otherwise you can find good startup guides in the following guides:

- [Go download and install][https://golang.org/doc/install]
- [Go compile and install an application](https://golang.org/doc/tutorial/compile-install)
- [Go GOOS and GOARCH reference gist](https://gist.github.com/asukakenji/f15ba7e588ac42795f421b48b8aede63)

Example for Linux on x86_64 host:

```sh
cd PATH/TO/dpn/utils/go-aws-secrets-manager
GOOS=linux GOARH=amd64 go build -o datadog-secrets-aws
sudo mv datadog-secrets-aws /YOUR/OWN/PATH
sudo chmod 700 <path_to_executable>
sudo chown dd-agent <path_to_exectuable>
```

Example for Windows on x86_64 host:

```
cd PATH\TO\dpn\utils\go-aws-secrets-manager
GOOS=windows GOARH=amd64 go build -o datadog-secrets-aws.exe
```

Then refer to the instruction for Windows [in the Windows section](### On Windows)


### Store a new secret

Go to AWS Secrets Manager and store a new secret:

![fig3](https://p-qkfgo2.t2.n0.cdn.getcloudapp.com/items/jkuEgbq7/f3b49093-23f2-4e83-b82a-20e4bcff0d1b.jpg?source=viewer&v=2d412bdf7dc5b481ff949a2f867f87b2)

Choose key/value pair:

![fig4](https://p-qkfgo2.t2.n0.cdn.getcloudapp.com/items/z8u1AeqO/6a2fac1a-bc5a-40b1-b808-6cfac23bbc73.jpg?source=viewer&v=6b57af7c6c23cde31e3227ecdf05bb1b)

The key MUST be **dd-secret** in order to let the tool retrieve it. Enter the secret value and go to the next step.

![fig5](https://p-qkfgo2.t2.n0.cdn.getcloudapp.com/items/YEuPGndB/cf57e9f5-2b3c-4687-8f35-4f62eb795dc8.jpg?source=viewer&v=3618f7f9a8ab6361693d84e889549d3a)

Give a name to your secret and an optional description, then go to the next step.

![fig6](https://p-qkfgo2.t2.n0.cdn.getcloudapp.com/items/YEuPGndB/cf57e9f5-2b3c-4687-8f35-4f62eb795dc8.jpg?source=viewer&v=3618f7f9a8ab6361693d84e889549d3a)

Just click on next.

There is nothing to do for the step 4, just click **store** to store your new secret:

![fig7](https://p-qkfgo2.t2.n0.cdn.getcloudapp.com/items/wbu8ZEmK/f5c7344f-e42c-4920-a978-e06142066e1c.jpg?source=viewer&v=8010345be61a6ae4d5e3ee77107606fb)

## Try it out!

### On Linux

Verify your setup:

![fig8](https://p-qkfgo2.t2.n0.cdn.getcloudapp.com/items/P8u80AKA/732e6855-d95d-4acc-8ed4-4c53a88194a4.jpg?source=viewer&v=55978c888224a292093a43f29c01bfde)

Try to use it manually:

![fig9](https://p-qkfgo2.t2.n0.cdn.getcloudapp.com/items/yAu0X5NR/7e7ad576-cf16-4e02-b3e3-39f728b064ab.jpg?source=viewer&v=44f2c711b96a0adef450e2594317c0e0)

```bash
sudo su dd-agent -s /bin/bash -c "echo '{\"version\": \"1.0\", \"secrets\": [\"my-secret-env\"]}'|/usr/local/bin/datadog-secrets-aws"
{"my-secret-env":{"value":"test","error":""}}
```

Use it with the agent:

```
sudo vi /etc/datadog-agent/datadog.yaml

## @param env - string - optional
## @env DD_ENV - string - optional
## The environment name where the agent is running. Attached in-app to every
## metric, event, log, trace, and service check emitted by this Agent.
#
env: "ENC[my-secret-env]"

[...]

## @param secret_backend_command - string - optional
## `secret_backend_command` is the path to the script to execute to fetch secrets.
## The executable must have specific rights that differ on Windows and Linux.
##
## For more information see: https://github.com/DataDog/datadog-agent/blob/main/docs/agent/secrets.md
#
secret_backend_command: /usr/local/bin/datadog-secrets-aws
```

Restart the agent

```bash
sudo systemctl restart datadog-agent
```

Check agent status:

![fig10](https://p-qkfgo2.t2.n0.cdn.getcloudapp.com/items/RBuE65EO/32021b6f-841c-437a-a160-f056ea038f05.jpg?source=viewer&v=32949cd192058303bcac23e9a42cbb2b)

### On Windows

> You need to rely more on the CLI than the WebUI, because when the agent doesn’t start, you have to figure out why with the log file and the agent output.

Copy the .exe on the local filesystem.

Change the configuration of the Datadog agent:

```yaml
## @param env - string - optional
## @env DD_ENV - string - optional
## The environment name where the agent is running. Attached in-app to every
## metric, event, log, trace, and service check emitted by this Agent.
#
env: "ENC[my-secret-env]"
[...]
## @param secret_backend_command - string - optional
## `secret_backend_command` is the path to the script to execute to fetch secrets.
## The executable must have specific rights that differ on Windows and Linux.
##
## For more information see: https://github.com/DataDog/datadog-agent/blob/main/docs/agent/secrets.md
#
secret_backend_command: 'C:\Program Files\Datadog\Datadog Agent\bin\datadog-secrets-aws.exe'
```

Before restarting the agent, check that you’ve set the correct permissions on the .exe

Disable the inheritance and add SYSTEM and Administrator in Read and Execute:

![fig11](https://p-qkfgo2.t2.n0.cdn.getcloudapp.com/items/P8u8vZ2m/03b9db83-682c-45ce-b9f0-110cc46f16f2.jpg?source=viewer&v=6fe116bd3b30552d8f3a8db356c1a128)

Restart the agent:

![fig12](https://p-qkfgo2.t2.n0.cdn.getcloudapp.com/items/E0uKWGOj/772ef5d2-cbe6-4da6-817f-355c0303dad8.jpg?source=viewer&v=6e73b4412afd2359baa3e1d90669e186)

### Troubleshooting

If the agent doesn’t restart, try to run it manually:

```
"C:\Program Files\Datadog\Datadog Agent\bin\agent.exe start"
```

If you have an error that the agent can’t find the binary, check that you put the path in single quotes in the `datadog.yaml` file.

If the agent complains about permissions:

```
Error: unable to set up global agent configuration: unable to load Datadog 
config file: unable to decrypt secret from datadog.yaml: 
'S-1-5-21-1163014751-2161214003-1688321825-500' user is not allowed 
to execute secretBackendCommand 
'C:\Program Files\Datadog\Datadog Agent\bin\datadog-secrets-aws.exe'
```

And you have to figure out which user is `S-1-5-21-1163014751-2161214003-1688321825-500`, run the following command and then update your permissions accordingly:

```
wmic useraccount get name,sid
Name                SID
Administrator       S-1-5-21-1163014751-2161214003-1688321825-500
ddagentuser         S-1-5-21-1163014751-2161214003-1688321825-1008
DefaultAccount      S-1-5-21-1163014751-2161214003-1688321825-503
Guest               S-1-5-21-1163014751-2161214003-1688321825-501
WDAGUtilityAccount  S-1-5-21-1163014751-2161214003-1688321825-504
```

(c) Datadog 2021