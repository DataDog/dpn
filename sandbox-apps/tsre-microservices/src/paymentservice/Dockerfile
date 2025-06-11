# Chris: I'm commenting this out to test a few things. Need a proper shell with utilities and everything. We can always change this back later.
#FROM openjdk:17-jdk-alpine
FROM ubuntu:20.04 

# Chris: I'm also installing the utilities I need to debug some database issues I discovered. Need to comment out before we push this to production
RUN apt-get update
RUN apt-get install -y openjdk-17-jdk
RUN apt-get install -y mariadb-client
RUN apt-get install -y wget
RUN apt-get install -y curl vim
# Chris: I'm adding this to debug
RUN apt-get -y install sudo

RUN mkdir -p /app/data
RUN chmod -R 777 /app/data

# Chris: just testing something with version 0.6.1 - broke artifactory so will just use local builds for now. What could go wrong?
COPY releases/paymentservicejava-0.6.2.jar /app/paymentservice.jar

WORKDIR /app
RUN wget -O dd-java-agent.jar https://dtdg.co/latest-java-tracer
 
# Datadog - Enable tracer
ENV DD_PROFILING_ENABLED=true
ENV DD_LOGS_INJECTION=true
 
ENV JAVA_OPTS=-javaagent:dd-java-agent.jar

WORKDIR /app
ENTRYPOINT ["java","--add-opens","java.base/java.lang=ALL-UNNAMED","--add-opens","java.base/java.util=ALL-UNNAMED","-jar","/app/paymentservice.jar"]
EXPOSE 9090
EXPOSE 8881
