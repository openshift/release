#!/bin/bash
job="${TEST_SUITE:-${JOB_NAME_SAFE#merge-}}"
job="${job#nightly-}"

set -x

tee scripts/ci/jobs/shell-unit-tests.sh <<EOF
#!/usr/bin/env bash

set -x
ns="testname"
oc patch scc anyuid --type merge -p '{
    "allowHostDirVolumePlugin": true,
    "allowHostNetwork": true,
    "allowHostPorts": true,
    "allowPrivilegedContainer": true,
    "allowedCapabilities": [ "*" ],
    "requiredDropCapabilities": []
}'


oc create ns "${ns}"
oc patch scc anyuid --type json -p '[{ "op": "add", "path": "/users/-", "value": "system:serviceaccount:'"${ns}"':default" }]'
oc -n "${ns}" create deployment nginx --image=nginx
time oc -n "${ns}" rollout status deployment nginx -w

EOF

echo "Check script:"
cat scripts/ci/jobs/shell-unit-tests.sh

echo "Dispatch..."

exec .openshift-ci/dispatch.sh "${job}"
