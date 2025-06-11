FROM --platform=$BUILDPLATFORM python:3.13-slim as base

FROM base

RUN apt-get -qq update \
    && apt-get install -y --no-install-recommends \
        wget g++ \
    && rm -rf /var/lib/apt/lists/*

ARG TARGETOS
ARG TARGETARCH
RUN echo ${TARGETOS}
RUN echo ${TARGETARCH}

# get packages
COPY requirements.txt .
RUN pip install -r requirements.txt

# Enable unbuffered logging
ENV PYTHONUNBUFFERED=1

WORKDIR /app

# Add the application
COPY . .

ENTRYPOINT [ "python", "replay.py" ]
