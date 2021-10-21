#!/usr/bin/env bash

# This script will deploy STF.

set -o nounset
set -o errexit
set -o pipefail

# I think you'll need that
export KUBECONFIG=${SHARED_DIR}/kubeconfig
oc get nodes

# if you need to put stuffs in a shared dir between step registry:
echo foo > ${SHARED_DIR}/bar

# if you need to collect artifacts
echo foo > ${ARTIFACT_DIR}/bar

# install ansible, run ansible, etc.
