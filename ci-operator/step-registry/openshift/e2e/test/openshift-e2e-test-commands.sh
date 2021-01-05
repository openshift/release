#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json
export HOME=/tmp/home
export PATH=/usr/libexec/origin:$PATH

if [[ -n "${TEST_CSI_DRIVER_MANIFEST}" ]]; then
    export TEST_CSI_DRIVER_FILES=${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
fi

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

mkdir -p "${HOME}"

# Override the upstream docker.io registry due to issues with rate limiting
# https://bugzilla.redhat.com/show_bug.cgi?id=1895107
# sjenning: TODO: use of personal repo is temporary; should find long term location for these mirrored images
export KUBE_TEST_REPO_LIST=${HOME}/repo_list.yaml
cat <<EOF > ${KUBE_TEST_REPO_LIST}
dockerLibraryRegistry: quay.io/sjenning
dockerGluster: quay.io/sjenning
EOF

# if the cluster profile included an insights secret, install it to the cluster to
# report support data from the support-operator
if [[ -f "${CLUSTER_PROFILE_DIR}/insights-live.yaml" ]]; then
    oc create -f "${CLUSTER_PROFILE_DIR}/insights-live.yaml" || true
fi

# set up cloud-provider-specific env vars
KUBE_SSH_BASTION="$( oc --insecure-skip-tls-verify get node -l node-role.kubernetes.io/master -o 'jsonpath={.items[0].status.addresses[?(@.type=="ExternalIP")].address}' ):22"
KUBE_SSH_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export KUBE_SSH_BASTION KUBE_SSH_KEY_PATH
case "${CLUSTER_TYPE}" in
gcp)
    export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"
    export KUBE_SSH_USER=core
    mkdir -p ~/.ssh
    cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" ~/.ssh/google_compute_engine || true
    export TEST_PROVIDER='{"type":"gce","region":"us-east1","multizone": true,"multimaster":true,"projectid":"openshift-gce-devel-ci"}'
    ;;
aws)
    mkdir -p ~/.ssh
    cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" ~/.ssh/kube_aws_rsa || true
    export PROVIDER_ARGS="-provider=aws -gce-zone=us-east-1"
    # TODO: make openshift-tests auto-discover this from cluster config
    REGION="$(oc get -o jsonpath='{.status.platformStatus.aws.region}' infrastructure cluster)"
    ZONE="$(oc get -o jsonpath='{.items[0].metadata.labels.failure-domain\.beta\.kubernetes\.io/zone}' nodes)"
    export TEST_PROVIDER="{\"type\":\"aws\",\"region\":\"${REGION}\",\"zone\":\"${ZONE}\",\"multizone\":true,\"multimaster\":true}"
    export KUBE_SSH_USER=core
    ;;
azure4) export TEST_PROVIDER=azure;;
vsphere) export TEST_PROVIDER=vsphere;;
openstack) export TEST_PROVIDER='{"type":"openstack"}';;
ovirt) export TEST_PROVIDER='{"type":"ovirt"}';;
openstack-vexxhost) export TEST_PROVIDER='{"type":"openstack"}';;
kubevirt) export TEST_PROVIDER='{"type":"kubevirt"}';;
*) echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"; exit 1;;
esac

mkdir -p /tmp/output
cd /tmp/output

if [[ "${CLUSTER_TYPE}" == gcp ]]; then
    pushd /tmp
    curl -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-256.0.0-linux-x86_64.tar.gz
    tar -xzf google-cloud-sdk-256.0.0-linux-x86_64.tar.gz
    export PATH=$PATH:/tmp/google-cloud-sdk/bin
    mkdir gcloudconfig
    export CLOUDSDK_CONFIG=/tmp/gcloudconfig
    gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
    gcloud config set project openshift-gce-devel-ci
    popd
fi

case "${TEST_TYPE}" in
upgrade-conformance)
    export SHOULD_TEST=1
    export SHOULD_UPGRADE=1
    export TEST_SUITE=openshift/conformance/parallel # TODO: switch to openshift/conformance after we assess test time
    ;;
upgrade)
    export SHOULD_UPGRADE=1
    ;;
suite)
    export SHOULD_TEST=1
    ;;
*)
    echo >&2 "Unsupported test type '${TEST_TYPE}'"
    exit 1
    ;;
esac

if [[ -n "${SHOULD_UPGRADE-}" ]]; then
    set -x
    openshift-tests run-upgrade all \
        --to-image "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}" \
        --options "${TEST_UPGRADE_OPTIONS-}" \
        --provider "${TEST_PROVIDER}" \
        -o /tmp/artifacts/e2e.log \
        --junit-dir /tmp/artifacts/junit
    set +x
fi

if [[ -n "${SHOULD_TEST-}" ]]; then
    if [[ -n "${TEST_SKIPS}" ]]; then
        TESTS="$(openshift-tests "${TEST_COMMAND}" --dry-run "${TEST_SUITE}")"
        echo "${TESTS}" | grep -v "${TEST_SKIPS}" >/tmp/tests
        echo "Skipping tests:"
        echo "${TESTS}" | grep "${TEST_SKIPS}"
        TEST_ARGS="${TEST_ARGS:-} --file /tmp/tests"
    fi

    set -x
    openshift-tests run "${TEST_SUITE}" ${TEST_ARGS:-} \
        --provider "${TEST_PROVIDER}" \
        -o /tmp/artifacts/e2e.log \
        --junit-dir /tmp/artifacts/junit
    set +x
fi