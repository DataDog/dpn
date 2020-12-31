#!/bin/bash

# Unless explicitly stated otherwise all files in this repository are licensed under the Apache 2.0 License.
# This product includes software developed at Datadog (https://www.datadoghq.com/). Copyright 2020 Datadog, Inc.

# called by the sandbox app's ./setup.sh script

curl -X POST "https://browser-http-intake.logs.datadoghq.com/v1/input/${DPN_STRING}" \
-H "Content-Type: application/json" \
-d @- << EOF
{
	"message": "completed provisioning a sandbox app", 
	"status": "info",
	"sandbox-app": "voting-app",
	"tag_defaults": "${TAG_DEFAULTS}",
	"hostname_base": "${HOSTNAME_BASE}",
	"step": "end",
	"type": "${TYPE:-"None"}"
}
EOF

echo "Operation complete!"
