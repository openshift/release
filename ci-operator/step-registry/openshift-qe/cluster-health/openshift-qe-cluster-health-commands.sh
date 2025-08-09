#!/bin/bash
set -eu

if [ ${PUBLIC_VLAN} == "true" ]; then
  oc version
  oc get node
  oc adm wait-for-stable-cluster --minimum-stable-period=${MINIMUM_STABLE_PERIOD} --timeout=${TIMEOUT}
fi
