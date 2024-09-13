#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x


echo "Env check"
whoami
which podman

podman pull quay.io/opendatahub/opendatahub-operator:latest
