#!/bin/bash

# Unless explicitly stated otherwise all files in this repository are licensed under the Apache 2.0 License.
# This product includes software developed at Datadog (https://www.datadoghq.com/). Copyright 2020 Datadog, Inc.

# translate setup.env to unix-friendly just in case it came from dos
sudo sed -e "s/\r//g" setup.env > setup.env.new
sudo mv setup.env.new setup.env

# get env variables
. setup.env

# quit if any of the required vars are not set
. .require.vars.sh

# run preprovisioning
. .setup.pre.sh

# Clone the app repo
echo "cloning app repo"

# create RUM project
response=$(curl -X POST "https://api.datadoghq.com/api/v1/rum/projects" \
-H "Content-Type: application/json" \
-H "DD-API-KEY: ${DD_API_KEY}" \
-H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
-d @- << EOF
{
  "name": "storedog-${HOSTNAME_BASE}"
}
EOF
)
RUM_ID=$(echo $response | jq -r '.id')
RUM_HASH=$(echo $response | jq -r '.hash')

# setup
sudo git clone https://github.com/DataDog/ecommerce-workshop.git
sudo cp ./data/docker-compose.yml ./ecommerce-workshop/deploy/docker-compose/

cd ecommerce-workshop/deploy/docker-compose

sudo sed -i.bak "s|__TAGS__|${TAG_DEFAULTS}|g" ./docker-compose.yml
sudo sed -i.bak "s|__HOSTNAME_BASE__|${HOSTNAME_BASE}|g" ./docker-compose.yml
sudo sed -i.bak "s|__PG_USER__|${PG_USER}|g" ./docker-compose.yml
sudo sed -i.bak "s|__PG_PASS__|${PG_PASS}|g" ./docker-compose.yml

# deploy 
sudo POSTGRES_USER=${PG_USER:-e.alderson} POSTGRES_PASSWORD=${PG_PASS:-the9cake4is8a3lie} DD_API_KEY=${DD_API_KEY} DD_CLIENT_TOKEN=${RUM_HASH} DD_APPLICATION_ID=${RUM_ID} docker-compose -f docker-compose.yml up -d

# make a couple requests
curl localhost:8000
curl localhost:8080

# run postprovisioning
cd ../../../
. ./.setup.post.sh

echo """
Completed provisioning. 
Check your Datadog account for the storedog-${HOSTNAME_BASE} application. 
Make requests on ports 8000 for the healthy version fo the app, 
and on port 8080 for the unhealthy version of the app.
"""
