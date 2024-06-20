#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ assisted common verify command ************"

if [ "${TEST_SUITE:-full}" == "none" ]; then
    echo "No need to run tests"
    exit 0
fi

function get_test_list() {
    podman run --network host --rm -i \
        -e KUBECONFIG=tmp/kubeconfig -v ${KUBECONFIG}:tmp/kubeconfig \
        ${OPENSHIFT_TESTS_IMAGE} openshift-tests run "openshift/conformance/parallel" --dry-run | \
        grep -Ff ${SHARED_DIR}/test-list
}

function run_tests() {
    podman run --network host --rm -i -v ${ARTIFACT_DIR}:${ARTIFACT_DIR} \
        openshift-tests run -o ${ARTIFACT_DIR}/e2e.log \
        --junit-dir ${ARTIFACT_DIR}/reports -f -
}
unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS

case "${CLUSTER_TYPE}" in
    vsphere)
        # shellcheck disable=SC1090
        source "${SHARED_DIR}/govc.sh"
        export VSPHERE_CONF_FILE="${SHARED_DIR}/vsphere.conf"
        oc -n openshift-config get cm/cloud-provider-config -o jsonpath='{.data.config}' > "$VSPHERE_CONF_FILE"
        # The test suite requires a vSphere config file with explicit user and password fields.
        sed -i "/secret-name \=/c user = \"${GOVC_USERNAME}\"" "$VSPHERE_CONF_FILE"
        sed -i "/secret-namespace \=/c password = \"${GOVC_PASSWORD}\"" "$VSPHERE_CONF_FILE"
        export TEST_PROVIDER=vsphere
        ;;

    packet-edge|nutanix)
        export TEST_PROVIDER=baremetal
        ;;

    *)
        echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
        exit 1
        ;;
esac

export KUBECONFIG=${SHARED_DIR}/kubeconfig
mkdir -p ${ARTIFACT_DIR}/reports

get_test_list | run_tests

