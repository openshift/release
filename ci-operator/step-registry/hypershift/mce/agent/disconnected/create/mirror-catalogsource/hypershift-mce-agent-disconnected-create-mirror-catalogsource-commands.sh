#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ create mirror-catalogsource command ************"

source "${SHARED_DIR}/packet-conf.sh"

ssh "${SSHOPTS[@]}" "root@${IP}" bash - << 'EOF' |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'
function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}
function check_marketplace () {
    ret=0
    run_command "oc get ns openshift-marketplace" || ret=$?
    if [[ $ret -eq 0 ]]; then
        echo "openshift-marketplace project AlreadyExists, skip creating."
        return 0
    fi

    cat <<END | oc create -f -
apiVersion: v1
kind: Namespace
metadata:
  labels:
    security.openshift.io/scc.podSecurityLabelSync: "false"
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/warn: baseline
  name: openshift-marketplace
END
}

cd /root/dev-scripts
source common.sh
MANIFESTS_DIR="${OCP_DIR}/manifests"

export KUBECONFIG=/root/nested_kubeconfig
check_marketplace
oc apply -f ${MANIFESTS_DIR}/catalogSource.yaml
EOF
