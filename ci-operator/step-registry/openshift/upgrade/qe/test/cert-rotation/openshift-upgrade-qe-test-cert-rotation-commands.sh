#!/bin/bash
set -xeuo pipefail

function extract_oc(){
    mkdir -p /tmp/client
    export OC_DIR="/tmp/client"
    export PATH=${OC_DIR}:$PATH

    echo -e "Extracting oc\n"
    local retry=5 tmp_oc="/tmp/client-2"
    mkdir -p ${tmp_oc}
    while ! (env "NO_PROXY=*" "no_proxy=*" oc adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" --command=oc --to=${tmp_oc} ${RELEASE_IMAGE_TARGET});
    do
        echo >&2 "Failed to extract oc binary, retry..."
        (( retry -= 1 ))
        if (( retry < 0 )); then return 1; fi
        sleep 60
    done
    mv ${tmp_oc}/oc ${OC_DIR} -f
    which oc
    oc version --client
    return 0
}

extract_oc

if [[ -f "${SHARED_DIR}/kubeconfig" ]] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

# Setup proxy if it's present in the shared dir
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

oc adm wait-for-stable-cluster --minimum-stable-period=5s
# Let's start with the MCO cert rotation
oc adm ocp-certificates regenerate-machine-config-server-serving-cert
# A few preparatory rotations
oc adm ocp-certificates regenerate-leaf -n openshift-config-managed secrets kube-controller-manager-client-cert-key kube-scheduler-client-cert-key
oc adm ocp-certificates regenerate-leaf -n openshift-kube-apiserver-operator secrets node-system-admin-client
oc adm ocp-certificates regenerate-leaf -n openshift-kube-apiserver secrets check-endpoints-client-cert-key control-plane-node-admin-client-cert-key  external-loadbalancer-serving-certkey internal-loadbalancer-serving-certkey kubelet-client localhost-recovery-serving-certkey localhost-serving-cert-certkey service-network-serving-certkey
oc adm wait-for-stable-cluster
