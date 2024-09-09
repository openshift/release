#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


# Fix user IDs in a container
~/fix_uid.sh

export KUBECONFIG=${SHARED_DIR}/kubeconfig

oc get csv -A