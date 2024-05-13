#!/bin/bash

set -ex

echo "************ hypershift disconnected nfs command ************"

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi
if [ -f "${SHARED_DIR}/ds-vars.conf" ] ; then
  source "${SHARED_DIR}/ds-vars.conf"
fi
if [ -f "${SHARED_DIR}/packet-conf.sh" ] ; then
  source "${SHARED_DIR}/packet-conf.sh"
fi

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF
oc image mirror --registry-config ${DS_WORKING_DIR}/pull_secret.json quay.io/hypershift/hypershift-operator:latest  $DS_REGISTRY/hypershift/hypershift-operator:latest
EOF

echo "$DS_REGISTRY" > "${SHARED_DIR}/mirror_registry_url"