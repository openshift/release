#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

oc label nodes -l node-role.kubernetes.io/worker= scale.spectrum.ibm.com/role=storage --overwrite

typeset labeledCount=0
labeledCount=$(oc get nodes -l scale.spectrum.ibm.com/role=storage --no-headers | wc -l)

((labeledCount == 0)) && false

true
