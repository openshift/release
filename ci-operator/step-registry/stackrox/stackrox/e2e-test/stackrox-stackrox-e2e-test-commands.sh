#!/bin/bash
export OPENSHIFT_CI_STEP_NAME="stackrox-stackrox-e2e-test"
job="${TEST_SUITE:-${JOB_NAME_SAFE#merge-}}"
job="${job#nightly-}"
oc get nodes -A || true
oc get namespaces -A || true
oc get pods -A || true
ls -la
for I in {1..15}; do
  printf "$I %(%FT%T%z)T\n" -1
  sleep 60
done
oc get pods -A || true
#exec .openshift-ci/dispatch.sh "${job}"
