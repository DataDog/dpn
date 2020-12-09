#!/bin/bash

# Unless explicitly stated otherwise all files in this repository are licensed under the Apache 2.0 License.
# This product includes software developed at Datadog (https://www.datadoghq.com/). Copyright 2020 Datadog, Inc.


# translate setup.env to unix-friendly just in case it came from dos
sudo sed -e "s/\r//g" setup.env > setup.env.new
sudo mv setup.env.new setup.env

# get env variables
. setup.env


START_DIR=$(pwd)

echo "Provisioning!"

echo "apt-get updating"
sudo apt-get update
echo "install curl if not there..."
sudo apt-get -y install curl
echo "installing git if not there..."
sudo apt-get -y install git

DPN_STRING="puba793760ef4e28fab630a7f13eda9e213"
curl -X POST https://browser-http-intake.logs.datadoghq.com/v1/input/${DPN_STRING} \
-H "Content-Type: application/json" \
-d @- << EOF
{
	"message": "started provisioning a sandbox app", 
	"status": "info",
	"sandbox-app": "sandbox-app-todo",
	"tag_defaults": "${TAG_DEFAULTS}",
	"hostname_base": "${HOSTNAME_BASE}",
	"step": "start"
}
EOF

echo "installing docker if not there..."
sudo curl -sSL https://get.docker.com/ | sh
# echo "installing agent container..."
# sudo docker run -d --name datadog-agent -e DD_API_KEY=${DD_API_KEY} -e DD_LOGS_ENABLED=true -e DD_LOGS_CONFIG_CONTAINER_COLLECT_ALL=true -e DD_AC_EXCLUDE="name:datadog-agent" -v /var/run/docker.sock:/var/run/docker.sock:ro -v /proc/:/host/proc/:ro -v /opt/datadog-agent/run:/opt/datadog-agent/run:rw -v /sys/fs/cgroup/:/host/sys/fs/cgroup:ro datadog/agent:latest
echo "installing docker-compose"
sudo curl -L "https://github.com/docker/compose/releases/download/1.25.5/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
sudo docker-compose --version

# install npm
sudo curl -sL https://deb.nodesource.com/setup_14.x | sudo -E bash -
sudo apt-get install -y nodejs


# Step 1: Clone the partner app repo
sudo git clone https://github.com/nxnarbais/dd-partner-app
cd dd-partner-app/nodejs-dummy
# Step 2: Clone demoapp, install it
sudo git clone https://github.com/benc-uk/nodejs-demoapp app
cd app/src
sudo npm install
# npm start
# echo "app started, you can see it running from http://localhost:3000"

# Step 3: Configure the containerized agent
cd $START_DIR/dd-partner-app/nodejs-dummy
sudo cp .env.example .env
sudo sed -i.bak "s/DD_API_KEY=123abc/DD_API_KEY=${DD_API_KEY}/g" .env
sudo sed -i.bak "s/- DD_HOSTNAME=localpro/- DD_HOSTNAME=${HOSTNAME_BASE}.dd-partner-app/g" docker-compose.yaml
sudo sed -i.bak "s/- DD_TAGS=env:local owner:narbais/- DD_TAGS=${TAG_DEFAULTS} env:dpn-sandbox app:dpn-node-app-1 owner:dpn-partner/g" docker-compose.yaml

# step 4: Instrument APM
cd app/src
sudo npm install --save dd-trace
# sudo sed -i.bak "s/console.log('### Node.js demo app starting...')\n/console.log('### Node.js demo app starting...')\nconst tracer = require('dd-trace').init()\n/g" server.js
sudo sed -i.bak "s/console.log('### Node.js demo app starting...')/console.log('### Node.js demo app starting...')\nconst tracer = require('dd-trace').init({\n  logInjection: true, \n  analytics: true, \n  runtimeMetrics: true, \n  tags: {\n    serviceteam: \"dogdemo\"\n  },\n});\n/g" server.js


# Step 5: install and configure winston
sudo npm install winston
echo """
const winston = require('winston');
const wlogger = winston.createLogger({
  level: 'info',
  format: winston.format.json(),
  transports: [
    new winston.transports.Console(),
  ]
});
module.exports = wlogger;
""" | sudo tee -a wlogger.js

sudo sed -i.bak "s/const app = express()/const app = express()\nconst wlogger = require('.\/wlogger');\n/g" server.js
sudo sed -i.bak "s/app.use(logger('dev'))/\/\/ app.use(logger('dev'))\nclass MyStream {\n  write(text) {\n      wlogger.info(text)\n  }\n}\nlet myStream = new MyStream()\napp.use(logger('combined', { stream: myStream }));/g" server.js
sudo sed -i.bak 's/console.error(`### ERROR: ${err.message}`)/wlogger.error(`### ERROR: ${err.message}`)/g' server.js
sudo sed -i.bak "s/class Utils {/const wlogger = require('..\/wlogger');\nclass Utils {/g" todo/utils.js
sudo sed -i.bak "s/console.dir(err)/\/\/ console.dir(err)/g" todo/utils.js
sudo sed -i.bak 's/console.log(`### Error with API ${JSON.stringify(err)}`)/wlogger.error(`### Error with API ${JSON.stringify(err)}`)/g' todo/utils.js

# step 6 TODO: add RUM

# Step 7: start the application
cd $START_DIR/dd-partner-app/nodejs-dummy
sudo docker network create my-net
sudo docker-compose up -d

curl -X POST https://browser-http-intake.logs.datadoghq.com/v1/input/${DPN_STRING} \
-H "Content-Type: application/json" \
-d @- << EOF
{
	"message": "completed provisioning a sandbox app", 
	"status": "info",
	"sandbox-app": "sandbox-app-todo",
	"tag_defaults": "${TAG_DEFAULTS}",
	"hostname_base": "${HOSTNAME_BASE}",
	"step": "end"
}
EOF
