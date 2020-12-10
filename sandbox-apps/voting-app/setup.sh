#!/bin/bash

# Unless explicitly stated otherwise all files in this repository are licensed under the Apache 2.0 License.
# This product includes software developed at Datadog (https://www.datadoghq.com/). Copyright 2020 Datadog, Inc.


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

echo "installing docker..."
sudo curl -sSL https://get.docker.com/ | sh
echo "installing docker-compose"
sudo curl -L "https://github.com/docker/compose/releases/download/1.25.5/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
sudo docker-compose --version

# Clone the app repo
echo "cloning app repo"
sudo git clone https://github.com/dockersamples/example-voting-app.git
cd example-voting-app

# replace username and passwords with setup.env input:
psqlconnstring="Server=db;Username=${PG_USER:-e.alderson};Password=${PG_PASS:-the9cake4is8a3lie};"
sudo sed -i.bak "s|var pgsql = OpenDbConnection(\"Server=db;Username=postgres;Password=postgres;\");|var pgsql = OpenDbConnection(\"${psqlconnstring}\");|g" ./worker/src/Worker/Worker.csproj
sudo sed -i.bak "s|POSTGRES_USER: \"postgres\"|POSTGRES_USER: \"${PG_USER:-e.alderson}\"|g" $HOME/data/docker-compose-dotnetworker.yml
sudo sed -i.bak "s|POSTGRES_PASSWORD: \"postgres\"|POSTGRES_PASSWORD: \"${PG_PASS:-the9cake4is8a3lie}\"|g" $HOME/data/docker-compose-dotnetworker.yml
sudo sed -i.bak "s|conn = DriverManager.getConnection(url, \"postgres\", \"postgres\");|conn = DriverManager.getConnection(url, \"${PG_USER:-e.alderson}\", \"${PG_PASS:-the9cake4is8a3lie}\");|g" ./worker/src/main/java/worker/Worker.java
sudo sed -i.bak "s|POSTGRES_USER: \"postgres\"|POSTGRES_USER: \"${PG_USER:-e.alderson}\"|g" $HOME/data/docker-compose-javaworker.yml
sudo sed -i.bak "s|POSTGRES_PASSWORD: \"postgres\"|POSTGRES_PASSWORD: \"${PG_PASS:-the9cake4is8a3lie}\"|g" $HOME/data/docker-compose-javaworker.yml
sudo sed -i.bak "s|connectionString: 'postgres://postgres:postgres@db/postgres'|connectionString: \"postgres://${PG_USER:-e.alderson}:${PG_PASS:-the9cake4is8a3lie}@db/postgres\"|g" ./result/server.js

# this part will be for Java, once we add support for it. 
echo "configure the docker-compose file and envs"
sudo cp $HOME/data/docker-compose-javaworker.yml ./
sudo sed -i.bak "s/<DD_API_KEY>/${DD_API_KEY}/g" docker-compose-javaworker.yml
sudo sed -i.bak "s/<DD_SITE>/${DD_SITE}/g" docker-compose-javaworker.yml
sudo sed -i.bak "s/<HOSTNAME_BASE>/${HOSTNAME_BASE}/g" docker-compose-javaworker.yml
sudo sed -i.bak "s/<TAG_DEFAULTS>/${TAG_DEFAULTS}/g" docker-compose-javaworker.yml

# install java tracer library
sudo wget -O worker/dd-java-agent.jar 'https://dtdg.co/latest-java-tracer'

# the maven install is crazy verbose, let's quiet that down
sudo sed -i.bak "s/\"mvn\",/\"mvn\",\"-q\",/g" ./worker/Dockerfile.j
sudo sed -i.bak 's|CMD \["java", "-XX:+UnlockExperimentalVMOptions", "-XX:+UseCGroupMemoryLimitForHeap", "-jar", "/worker-jar-with-dependencies.jar"\]|CMD \["java", "-javaagent:/dd-java-agent.jar", "-Ddd.trace.analytics.enabled=true", "-Ddatadog.slf4j.simpleLogger.defaultLogLevel=debug", "-Ddd.trace.methods=worker.Worker\[updateVote,connectToRedis,connectToDB\]", "-jar", "/worker-jar-with-dependencies.jar"\]|g' ./worker/Dockerfile.j

# sudo sed -i.bak "s|<version>9.4-1200-jdbc41</version>|<version>9.4-1200-jdbc41</version>\n    </dependency>\n    <dependency>\n      <groupId>com.datadoghq</groupId>\n      <artifactId>dd-trace-api</artifactId>\n      <version>0.59.0</version>\n    </dependency>\n    <!-- OpenTracing API -->\n    <dependency>\n      <groupId>io.opentracing</groupId>\n      <artifactId>opentracing-api</artifactId>\n      <version>0.31.0</version>\n    </dependency>\n    <!-- OpenTracing Util -->\n    <dependency>\n      <groupId>io.opentracing</groupId>\n      <artifactId>opentracing-util</artifactId>\n      <version>0.31.0</version>\n    </dependency>|g" ./worker/pom.xml
sudo sed -i.bak 's|<version>9.4-1200-jdbc41</version>|<version>9.4-1200-jdbc41</version>\n    </dependency>\n    <dependency>\n      <groupId>com.datadoghq</groupId>\n      <artifactId>dd-trace-api</artifactId>\n      <version>0.59.0</version>\n    </dependency>\n    <!-- OpenTracing API -->\n    <dependency>\n      <groupId>io.opentracing</groupId>\n      <artifactId>opentracing-api</artifactId>\n      <version>0.31.0</version>\n    </dependency>\n    <!-- OpenTracing Util -->\n    <dependency>\n      <groupId>io.opentracing</groupId>\n      <artifactId>opentracing-util</artifactId>\n      <version>0.31.0</version>\n|g' ./worker/pom.xml

# for .NET
echo "configure the docker-compose file and envs..."
sudo cp $HOME/data/docker-compose-dotnetworker.yml ./docker-compose.yml
sudo sed -i.bak "s/<DD_API_KEY>/${DD_API_KEY}/g" docker-compose.yml
sudo sed -i.bak "s/<DD_SITE>/${DD_SITE}/g" docker-compose.yml
sudo sed -i.bak "s/<HOSTNAME_BASE>/${HOSTNAME_BASE}/g" docker-compose.yml
sudo sed -i.bak "s/<TAG_DEFAULTS>/${TAG_DEFAULTS}/g" docker-compose.yml

echo "add python apm..."
echo 'ddtrace[profile]' | sudo tee -a ./vote/requirements.txt
sudo sed -i.bak "s/FROM python:2.7-alpine/FROM python:2/g" ./vote/Dockerfile  # alpine doens't ootb have the tooling that we need to autoinstrument
sudo sed -i.bak "s/\[\"gunicorn\",/\[\"ddtrace-run\", \"gunicorn\",/g" ./vote/Dockerfile  # not used, but just to make sure

echo "add nodejs apm..."
sudo sed -i.bak "s/var express = require('express'),/const tracer = require('dd-trace').init();\n\nvar express = require('express'),/g" ./result/server.js
# reduce frequency of postgres queries since they're very spammy
sudo sed -i.bak "s/setTimeout(function() {getVotes(client) }, 1000)/setTimeout(function() {getVotes(client) }, 10000)/g" ./result/server.js
sudo sed -i.bak "s/RUN npm install -g nodemon/RUN npm install -g nodemon\nRUN npm install --save dd-trace/g" ./result/Dockerfile

if [ $TYPE = "dotnet" ]
then
	echo "add .NET apm..."
	sudo wget https://github.com/DataDog/dd-trace-dotnet/releases/download/v1.18.3/datadog-dotnet-apm_1.18.3_amd64.deb
	sudo dpkg -i ./datadog-dotnet-apm_1.18.3_amd64.deb
	sudo mv datadog-dotnet-apm_1.18.3_amd64.deb ./worker/
	# add support for manual instrumentation too
	sudo sed -i.bak "s|<PackageReference Include=\"Newtonsoft.Json\" Version=\"12.0.1\" />|<PackageReference Include=\"Newtonsoft.Json\" Version=\"12.0.1\" />\n    <PackageReference Include=\"Datadog.Trace\" Version=\"1.18.3\" />|g" ./worker/src/Worker/Worker.csproj
	sudo cp $HOME/data/workerProgram.cs ./worker/src/Worker/Program.cs
	# add tracing library to Dockerfile
	sudo sed -i.bak "s|ADD src/Worker /code/src/Worker|ADD src/Worker /code/src/Worker\nCOPY datadog-dotnet-apm_1.18.3_amd64.deb /\nRUN dpkg -i /datadog-dotnet-apm_1.18.3_amd64.deb\nRUN dotnet add package Datadog.Trace --version 1.18.3|g" ./worker/Dockerfile

	# compose!
	sudo docker-compose up --build -d
else	
	sudo docker-compose -f docker-compose-javaworker.yml up --build -d
fi

# npm library won't install successfully with the result/Dockerfile RUN command and i can't understand why. this is a lame workaround. 
sudo docker exec example-voting-app_result_1 npm install --save dd-trace

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
