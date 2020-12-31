#!/bin/bash

# Unless explicitly stated otherwise all files in this repository are licensed under the Apache 2.0 License.
# This product includes software developed at Datadog (https://www.datadoghq.com/). Copyright 2020 Datadog, Inc.

# called by the sandbox app's ./setup.sh script

echo "Provisioning!"

echo "apt-get updating"
sudo apt-get update
echo "installing curl, git..."
sudo apt-get -y install curl git jq

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
	"type": "${TYPE:-"None"}"
}
EOF

echo "installing docker..."
sudo curl -sSL https://get.docker.com/ | sh
echo "installing docker-compose"
sudo curl -L "https://github.com/docker/compose/releases/download/1.25.5/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
sudo docker-compose --version