#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

oc get nodes -l node-role.kubernetes.io/worker

(($(oc get nodes -l node-role.kubernetes.io/worker= -o json | jq '.items | length') < 3)) && {
     : 'ERROR: Quorum requirement failed (min. of 3 worker nodes required)'
     false
}

true
