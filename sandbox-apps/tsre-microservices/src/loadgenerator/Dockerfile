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


# FROM python:3.11.1-slim@sha256:54924a2ee4a2ef17028ae076ce38e59b3f4054353a5c9f9318dfaee60377532c as base

# FROM base as builder

# COPY requirements.txt .

# RUN pip install --prefix="/install" -r requirements.txt

# FROM base

# WORKDIR /loadgen

# COPY --from=builder /install /usr/local

# # Add application code.
# COPY locustfile.py .

# # enable gevent support in debugger
# ENV GEVENT_SUPPORT=True

# ENTRYPOINT locust --host="http://${FRONTEND_ADDR}" --headless -u "${USERS:-10}" 2>&1

# Failing platform spec MANUALLY overridding it
FROM --platform=$BUILDPLATFORM python:3.9.15-slim as base

FROM base as builder

RUN apt-get -qq update \
    && apt-get install -y --no-install-recommends \
        g++

COPY requirements.txt .

RUN pip install --prefix="/install" -r requirements.txt

FROM base

WORKDIR /loadgen

COPY --from=builder /install /usr/local

# Add application code.
COPY locustfile.py .

# enable gevent support in debugger
ENV GEVENT_SUPPORT=True

ENTRYPOINT locust --host="http://${FRONTEND_ADDR}" --headless -u "${USERS:-10}" 2>&1
