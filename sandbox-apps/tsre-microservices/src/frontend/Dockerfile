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

# FROM golang:1.19.4-alpine@sha256:f33331e12ca70192c0dbab2d0a74a52e1dd344221507d88aaea605b0219a212f as builder

# Build xx
FROM --platform=$BUILDPLATFORM tonistiigi/xx AS xx

# Build Go
FROM --platform=$BUILDPLATFORM golang:1.20.5-alpine as builder

COPY --from=xx / /
ARG TARGETPLATFORM
RUN xx-info env

RUN apk add --no-cache ca-certificates git
RUN apk add build-base
RUN apk add clang lld


# alpine cross compile libraries
ARG TARGETPLATFORM
RUN echo "TARGETPLATFORM = ${TARGETPLATFORM}"
RUN xx-apk add --no-cache gcc musl-dev zlib-dev

WORKDIR /src

# restore dependencies
COPY go.mod go.sum ./
RUN go mod download
COPY . .

ARG TARGETOS 
ARG TARGETARCH
RUN echo "TARGETOS = ${TARGETOS}"
RUN echo "TARGETARCH = ${TARGETARCH}"

# Skaffold passes in debug-oriented compiler flags
ARG SKAFFOLD_GO_GCFLAGS
RUN echo "SKAFFOLD_GO_GCFLAGS = ${SKAFFOLD_GO_GCFLAGS}"
# Adding APP SEC 
ENV CGO_ENABLED=1
# RUN GOOS=$TARGETOS GOARCH=$TARGETARCH go build -v -tags appsec -gcflags="${SKAFFOLD_GO_GCFLAGS}" -o /go/bin/frontend .
RUN GOOS=$TARGETOS GOARCH=$TARGETARCH xx-go build -gcflags="${SKAFFOLD_GO_GCFLAGS}" -o /go/bin/frontend . && xx-verify /go/bin/frontend


FROM alpine:3.17.0 as release
RUN apk add --no-cache ca-certificates \
    busybox-extras net-tools bind-tools
WORKDIR /src
COPY --from=builder /go/bin/frontend /src/server
COPY ./templates ./templates
COPY ./static ./static

# Definition of this variable is used by 'skaffold debug' to identify a golang binary.
# Default behavior - a failure prints a stack trace for the current goroutine.
# See https://golang.org/pkg/runtime/
ENV GOTRACEBACK=single

EXPOSE 8080
ENTRYPOINT ["/src/server"]
