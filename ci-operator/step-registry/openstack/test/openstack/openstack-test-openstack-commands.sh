#!/usr/bin/env bash

set -Eeuo pipefail

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

openstack-tests run --run '\[Feature:openstack\]' openshift/conformance
