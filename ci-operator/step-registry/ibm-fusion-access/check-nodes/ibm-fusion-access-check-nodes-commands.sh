#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

oc get nodes -l node-role.kubernetes.io/worker=

(($(oc get nodes -l node-role.kubernetes.io/worker= -o json | jq '.items | length') < 3)) && {
     false
}

true
