!/bin/bash

echo 'Installing Datadog Agent on Amazon Linux...'

# Install Datadog Agent
DD_AGENT_MAJOR_VERSION=7 DD_API_KEY=$API_KEY_PLACEHOLDER DD_SITE="datadoghq.com" bash -c "$(curl -L https://s3.amazonaws.com/dd-agent/scripts/install_script.sh)"

# Force Copy datadog config file to target instance
cp ./datadog_example.yaml /etc/datadog-agent/datadog.yaml