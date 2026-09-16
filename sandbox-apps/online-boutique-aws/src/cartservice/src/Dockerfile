# Copyright 2021 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:7.0@sha256:81383de6f3bf443625eb277b203f6141f3496fd5a9e1b9b45a4c725266c9d92a AS build

ARG TARGETPLATFORM
ARG BUILDOS
ARG BUILDARCH
ARG TARGETOS 
ARG TARGETARCH
ARG ARCH
# RUN echo ${TARGETPLATFORM}
RUN echo ${TARGETOS}
RUN echo ${TARGETARCH}

WORKDIR /app
COPY . .
RUN dotnet restore cartservice.csproj
# RUN dotnet build "./cartservice.csproj" -c Debug -o /out

RUN if [ "$TARGETARCH" = "amd64" ]; then \
    RID=linux-x64 ; \
    elif [ "$TARGETARCH" = "arm64" ]; then \
    RID=linux-arm64 ; \
    fi \
    && dotnet build "./cartservice.csproj" -c Release -r $RID --no-self-contained -o /out

FROM build AS publish

ARG BUILDOS
ARG BUILDARCH
ARG TARGETOS 
ARG TARGETARCH
ARG ARCH
# RUN echo ${BUILDOS}
# RUN echo ${BUILDARCH}
RUN echo ${TARGETOS}
RUN echo ${TARGETARCH}

# RUN dotnet publish cartservice.csproj -c Debug -o /out

RUN if [ "$TARGETARCH" = "amd64" ]; then \
    RID=linux-x64 ; \
    elif [ "$TARGETARCH" = "arm64" ]; then \
    RID=linux-arm64 ; \
    fi \
    && dotnet publish cartservice.csproj -c Release -r $RID --no-self-contained -o /out

# Building final image used in running container
FROM mcr.microsoft.com/dotnet/aspnet:7.0@sha256:442e00363ed50e17c5104305b658d5d41cf857bbd9d81e9829bc70754169d995 AS final

ARG BUILDOS
ARG BUILDARCH
ARG TARGETOS 
ARG TARGETARCH
# RUN echo ${BUILDOS}
# RUN echo ${BUILDARCH}
RUN echo ${TARGETOS}
RUN echo ${TARGETARCH}

# Installing procps on the container to enable debugging of .NET Core
RUN apt-get update \
    && apt-get install -y unzip procps wget curl


# Download and install the Datadog Tracer
#ENV TRACER_VERSION=2.14.0
RUN mkdir -p /opt/datadog \
    && mkdir -p /var/log/datadog \
    && TRACER_VERSION=$(curl -s https://api.github.com/repos/DataDog/dd-trace-dotnet/releases/latest | grep tag_name | cut -d '"' -f 4 | cut -c2-) \
    && curl -LO https://github.com/DataDog/dd-trace-dotnet/releases/download/v${TRACER_VERSION}/datadog-dotnet-apm_${TRACER_VERSION}_${TARGETARCH}.deb \
    && dpkg -i ./datadog-dotnet-apm_${TRACER_VERSION}_${TARGETARCH}.deb \
    && /opt/datadog/createLogPath.sh \
    && rm ./datadog-dotnet-apm_${TRACER_VERSION}_${TARGETARCH}.deb


# renovate: datasource=github-releases depName=grpc-ecosystem/grpc-health-probe
# RUN GRPC_HEALTH_PROBE_VERSION=v0.4.14 && \
    # wget -qO/bin/grpc_health_probe https://github.com/grpc-ecosystem/grpc-health-probe/releases/download/${GRPC_HEALTH_PROBE_VERSION}/grpc_health_probe-linux-amd64 && \
    # chmod +x /bin/grpc_health_probe



RUN GRPC_HEALTH_PROBE_VERSION=v0.4.14 && \
    wget -qO/bin/grpc_health_probe https://github.com/grpc-ecosystem/grpc-health-probe/releases/download/${GRPC_HEALTH_PROBE_VERSION}/grpc_health_probe-linux-${TARGETARCH} && \
    chmod +x /bin/grpc_health_probe

WORKDIR /app
COPY --from=publish /out .
ENV ASPNETCORE_URLS=http://*:7070
ENV COMPlus_EnableDiagnostics=0
#Enable the tracer
ENV CORECLR_ENABLE_PROFILING=1
ENV CORECLR_PROFILER={846F5F1C-F9AE-4B07-969E-05C26BC060D8}
ENV CORECLR_PROFILER_PATH=/opt/datadog/Datadog.Trace.ClrProfiler.Native.so
ENV DD_DOTNET_TRACER_HOME=/opt/datadog
ENV DD_INTEGRATIONS=/opt/datadog/integrations.json
ENV LD_PRELOAD=/opt/datadog/continuousprofiler/Datadog.Linux.ApiWrapper.x64.so
ENV DD_PROFILING_ENABLED=1
ENV DD_TRACE_DEBUG=0
ENTRYPOINT ["dotnet", "cartservice.dll"]