#!/bin/bash

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# wait for all clusteroperators to reach progressing=false to ensure that we achieved the configuration specified at installation
# time before we run our e2e tests.
function check_clusteroperators_status() {
    echo "$(date) - waiting for clusteroperators to finish progressing..."
    oc wait clusteroperators --all --for=condition=Progressing=false --timeout=15m
    echo "$(date) - all clusteroperators are done progressing."
}

function mirror_nmstate_images_to_ds_registry() {
    source "${SHARED_DIR}/packet-conf.sh"
    source "${SHARED_DIR}/ds-vars.conf"

    echo "$(date) - mirroring ${HANDLER_IMAGE} and ${OPERATOR_IMAGE} to ${DS_REGISTRY}..."
    
    DST_HANDLER_IMAGE="${DS_REGISTRY}/nmstate/handler:ci"
    DST_OPERATOR_IMAGE="${DS_REGISTRY}/nmstate/operator:ci"
    
    ssh "${SSHOPTS[@]}" "root@${IP}" "oc image mirror $OPERATOR_IMAGE $DST_OPERATOR_IMAGE --registry-config=$DS_WORKING_DIR/pull_secret.json"
    ssh "${SSHOPTS[@]}" "root@${IP}" "oc image mirror $HANDLER_IMAGE $DST_HANDLER_IMAGE --registry-config=$DS_WORKING_DIR/pull_secret.json"

    export HANDLER_IMAGE=$DST_HANDLER_IMAGE
    export OPERATOR_IMAGE=$DST_OPERATOR_IMAGE
    
    echo "$(date) - mirrored to ${DST_HANDLER_IMAGE} and ${DST_OPERATOR_IMAGE}"
}

source "${SHARED_DIR}/dev-scripts-additional-config"
if [[ -n "${MIRROR_IMAGES}" ]]; then
    mirror_nmstate_images_to_ds_registry
fi

oc wait --for=condition=Progressing=False --timeout=2m clusterversion/version
check_clusteroperators_status

make test-e2e-handler-ocp
