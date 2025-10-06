#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

oc create namespace $NAMESPACE || true

make deploy-template

