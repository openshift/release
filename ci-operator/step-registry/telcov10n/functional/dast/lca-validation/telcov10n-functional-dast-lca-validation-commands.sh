#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


# Fix user IDs in a container
~/fix_uid.sh

KUBECONFIG="" oc --loglevel=8 registry login

oc get csv -A