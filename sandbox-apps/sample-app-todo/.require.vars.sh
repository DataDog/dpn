#!/bin/bash
#
# Unless explicitly stated otherwise all files in this repository are licensed under the Apache 2.0 License.
# This product includes software developed at Datadog (https://www.datadoghq.com/). Copyright 2020 Datadog, Inc.
#
# called by the sandbox app's ./setup.sh script

# quit if any of the required vars are not set
[ -z "$DD_API_KEY" ] && echo "make sure to set DD_API_KEY in your setup.env file. exiting." && exit 1
[ -z "$DD_APP_KEY" ] && echo "make sure to set DD_APP_KEY in your setup.env file. exiting." && exit 1
[ -z "$HOSTNAME_BASE" ] && echo "make sure to set HOSTNAME_BASE in your setup.env file. exiting." && exit 1
[ -z "$TAG_DEFAULTS" ] && echo "make sure to set TAG_DEFAULTS in your setup.env file. exiting." && exit 1
