#!/bin/bash

echo 'Uninstalling Datadog Agent on Amazon Linux...'

# Uninstall Agent -> https://docs.datadoghq.com/agent/guide/how-do-i-uninstall-the-agent
sudo yum remove datadog-agent
