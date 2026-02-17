#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

FA__SCALE__NAMESPACE="${FA__SCALE__NAMESPACE:-ibm-spectrum-scale}"

: 'Restarting GPFS daemon pods to pick up lxtrace files...'

oc delete pods -n "${FA__SCALE__NAMESPACE}" -l app.kubernetes.io/name=core --ignore-not-found

: 'Waiting for daemon pods to restart (max 10 minutes)...'

if oc wait --for=condition=Ready pod -l app.kubernetes.io/name=core \
    -n "${FA__SCALE__NAMESPACE}" --timeout=600s; then
  : 'All daemon pods running'
else
  : 'Timeout waiting for daemon pods'
  : 'Pod status:'
  oc get pods -n "${FA__SCALE__NAMESPACE}" -l app.kubernetes.io/name=core --ignore-not-found
fi

: 'Checking GPFS daemon state...'
pod=$(oc get pods -n "${FA__SCALE__NAMESPACE}" -l app.kubernetes.io/name=core -o name | head -1)
if [[ -n "$pod" ]]; then
  if ! oc exec -n "${FA__SCALE__NAMESPACE}" ${pod} -c gpfs -- mmgetstate -a; then
    : 'mmgetstate not available yet'
  fi
fi

: 'GPFS daemon pod restart complete'

true
