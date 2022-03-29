#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

cat >> /tmp/ipv6.yaml << EOF
- op: add
  path: /spec/clusterNetwork/-
  value:
    cidr: fd01::/48
    hostPrefix: 64
- op: add
  path: /spec/serviceNetwork/-
  value: fd02::/112
EOF

# This will likely be run right after a cluster install has completed so we should poll on clusteroperator
# status to be done progressing before applying the v6 config
case "${CLUSTER_TYPE}" in
packet|equinix*)
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/packet-conf.sh"
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/ds-vars.conf"

    if test -f "${SHARED_DIR}/proxy-conf.sh"
    then
        # shellcheck source=/dev/null
        source "${SHARED_DIR}/proxy-conf.sh"
    fi
    export KUBECONFIG=${SHARED_DIR}/kubeconfig

    if [[ "${DS_IP_STACK}" != "v6" ]];
    then
        export TEST_PROVIDER='{"type":"baremetal"}'
    else
        export TEST_PROVIDER='{"type":"baremetal","disconnected":true}'
    fi
    ;;
*) echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"; exit 1;;
esac

oc wait clusteroperators --all --for=condition=Progressing=false --timeout=15m
oc describe network -A
oc patch network.config.openshift.io cluster --type='json' --patch-file /tmp/ipv6.yaml
oc describe network -A