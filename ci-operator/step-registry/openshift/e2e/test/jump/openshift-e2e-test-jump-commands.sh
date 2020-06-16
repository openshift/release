#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export HOME=/tmp
export WORKSPACE=${WORKSPACE:-/tmp}
export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey

# This must match exactly to the openshift-e2e-test-commands.sh
cat >> ${WORKSPACE}/openshift-e2e-test-commands.sh << 'EOF'
#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json
export HOME=/tmp
export WORKSPACE=${WORKSPACE:-/tmp}
export PATH=/usr/libexec/origin:${WORKSPACE}:$PATH

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

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
*) echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"; exit 1;;
esac

mkdir -p ${WORKSPACE}/output
cd ${WORKSPACE}/output

if [[ "${CLUSTER_TYPE}" == gcp ]]; then
    pushd ${WORKSPACE}
    curl -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-256.0.0-linux-x86_64.tar.gz
    tar -xzf google-cloud-sdk-256.0.0-linux-x86_64.tar.gz
    export PATH=$PATH:${WORKSPACE}/google-cloud-sdk/bin
    mkdir gcloudconfig
    export CLOUDSDK_CONFIG=${WORKSPACE}/gcloudconfig
    gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
    gcloud config set project openshift-gce-devel-ci
    popd
fi

test_suite=openshift/conformance/parallel
if [[ -e "${SHARED_DIR}/test-suite.txt" ]]; then
    test_suite=$(<"${SHARED_DIR}/test-suite.txt")
fi

openshift-tests run "${test_suite}" \
    --provider "${TEST_PROVIDER}" \
    -o ${ARTIFACT_DIR}/e2e.log \
    --junit-dir ${ARTIFACT_DIR}/junit

EOF

run_rsync() {
  set -x
  rsync -PazcOq -e "ssh -o StrictHostKeyChecking=false -o UserKnownHostsFile=/dev/null -i ${SSH_PRIV_KEY_PATH}" "${@}"
  set +x
}

run_ssh() {
  set -x
  ssh -q -o StrictHostKeyChecking=false -o UserKnownHostsFile=/dev/null -i "${SSH_PRIV_KEY_PATH}" "${@}"
  set +x
}


REMOTE=$(<"${SHARED_DIR}/jump-host.txt") && export REMOTE
REMOTE_DIR="/tmp/install-$(date +%s%N)" && export REMOTE_DIR

if ! whoami &> /dev/null; then
  if [ -w /etc/passwd ]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
  fi
fi

run_ssh "${REMOTE}" -- mkdir -p "${REMOTE_DIR}/cluster_profile" "${REMOTE_DIR}/shared_dir" "${REMOTE_DIR}/artifacts_dir"
cat >> ${WORKSPACE}/runner.env << EOF
export RELEASE_IMAGE_LATEST="${RELEASE_IMAGE_LATEST}"

export CLUSTER_TYPE="${CLUSTER_TYPE}"
export CLUSTER_PROFILE_DIR="${REMOTE_DIR}/cluster_profile"
export ARTIFACT_DIR="${REMOTE_DIR}/artifacts_dir"
export SHARED_DIR="${REMOTE_DIR}/shared_dir"
export KUBECONFIG="${REMOTE_DIR}/shared_dir/kubeconfig"

export JOB_NAME="${JOB_NAME}"
export BUILD_ID="${BUILD_ID}"

export WORKSPACE=${REMOTE_DIR}
EOF

run_rsync "$(which openshift-tests)" "$(which oc)" ${WORKSPACE}/runner.env ${WORKSPACE}/openshift-e2e-test-commands.sh "${REMOTE}:${REMOTE_DIR}/"
run_ssh "${REMOTE}" 'for i in kubectl openshift-deploy openshift-docker-build openshift-sti-build openshift-git-clone openshift-manage-dockerfile openshift-extract-image-content openshift-recycle; do ln -sf '"${REMOTE_DIR}"'/oc '"${REMOTE_DIR}"'/$i; done'
run_rsync "${SHARED_DIR}/" "${REMOTE}:${REMOTE_DIR}/shared_dir/"
run_rsync "${CLUSTER_PROFILE_DIR}/" "${REMOTE}:${REMOTE_DIR}/cluster_profile/"

run_ssh "${REMOTE}" "source ${REMOTE_DIR}/runner.env && bash ${REMOTE_DIR}/openshift-e2e-test-commands.sh" &

set +e
wait "$!"
ret="$?"
set -e

run_rsync "${REMOTE}:${REMOTE_DIR}/shared_dir/" "${SHARED_DIR}/"
run_rsync --no-perms "${REMOTE}:${REMOTE_DIR}/artifacts_dir/" "${ARTIFACT_DIR}/"
run_ssh "${REMOTE}" "rm -rf ${REMOTE_DIR}"
exit "$ret"
