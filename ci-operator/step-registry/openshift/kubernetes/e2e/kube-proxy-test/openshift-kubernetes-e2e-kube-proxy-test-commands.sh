#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export ARTIFACTS="${ARTIFACT_DIR}"

# The following called script is maintained in openshift/kubernetes
# and added to the kubernetes-test binary. This is simpler to maintain
# since the tests and the wrapper that executes the m can be iterated
# on in a single PR.
# 4.17 and earlier that doesn't include the kube-proxy step, skip test kube-proxy.
# Detail see PR https://github.com/openshift/kubernetes/pull/2150
ocp_version=$(oc get -o jsonpath='{.status.desired.version}' clusterversion version)
major_version=$(echo ${ocp_version} | cut -d '.' -f1)
minor_version=$(echo ${ocp_version} | cut -d '.' -f2)
if [[ "X${major_version}" == "X4" && -n "${minor_version}" && "${minor_version}" -gt 17 ]]; then
    echo "Only run kube proxy e2e test on OCP 4.18+"
    test-kube-proxy.sh
else
    echo "Skip running kube proxy e2e test on OCP 4.17 and earlier"
fi
