# Copyright 2020 Google LLC
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

# FROM python:3.10.8-slim@sha256:49749648f4426b31b20fca55ad854caa55ff59dc604f2f76b57d814e0a47c181 as base

#FROM --platform=$BUILDPLATFORM python:3.10.8-slim as base
FROM --platform=$BUILDPLATFORM python:3.10.8-slim AS base
RUN echo "BUILDPLATFORM = ${BUILDPLATFORM}"

FROM base AS builder

RUN apt-get -qq update \
    && apt-get install -y --no-install-recommends \
        wget g++ \
    && rm -rf /var/lib/apt/lists/*

ARG TARGETOS 
ARG TARGETARCH
RUN echo ${TARGETOS}
RUN echo ${TARGETARCH}

# download the grpc health probe
# renovate: datasource=github-releases depName=grpc-ecosystem/grpc-health-probe
# RUN GRPC_HEALTH_PROBE_VERSION=v0.4.14 && \
#     wget -qO/bin/grpc_health_probe https://github.com/grpc-ecosystem/grpc-health-probe/releases/download/${GRPC_HEALTH_PROBE_VERSION}/grpc_health_probe-linux-amd64 && \
#     chmod +x /bin/grpc_health_probe

RUN GRPC_HEALTH_PROBE_VERSION=v0.4.14 && \
    wget -qO/bin/grpc_health_probe https://github.com/grpc-ecosystem/grpc-health-probe/releases/download/${GRPC_HEALTH_PROBE_VERSION}/grpc_health_probe-linux-${TARGETARCH} && \
    chmod +x /bin/grpc_health_probe

# get packages
COPY requirements.txt .
RUN pip install -r requirements.txt

FROM base AS without-grpc-health-probe-bin
# Enable unbuffered logging
ENV PYTHONUNBUFFERED=1

# get packages
WORKDIR /recommendationservice

# Grab packages from builder
COPY --from=builder /usr/local/lib/python3.10/ /usr/local/lib/python3.10/
COPY --from=builder /usr/local/bin/ /usr/local/bin/

# Add the application
COPY . .

# set listen port
ENV PORT=8080
EXPOSE 8080

ENTRYPOINT ["python", "recommendation_server.py"]

FROM without-grpc-health-probe-bin
COPY --from=builder /bin/grpc_health_probe /bin/grpc_health_probe