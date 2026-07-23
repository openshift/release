#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

typeset -i workerCount=0
workerCount=$(oc get nodes -l node-role.kubernetes.io/worker= -o jsonpath-as-json='{.items[*].metadata.name}' | jq 'length')
((workerCount >= 3))

true
