#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export PATH=/tmp/shared:$PATH

trap 'touch /tmp/shared/exit' EXIT
trap 'jobs -p | xargs -r kill || true; exit 0' TERM

function patch_image_specs() {
  cat <<EOF >samples-patch.yaml
- op: add
  path: /spec/skippedImagestreams
  value:
  - jenkins
  - jenkins-agent-maven
  - jenkins-agent-nodejs
EOF
  oc patch config.samples.operator.openshift.io cluster --type json -p "$(cat samples-patch.yaml)"

  NAMES='cli cli-artifacts installer installer-artifacts must-gather tests jenkins jenkins-agent-maven jenkins-agent-nodejs'
  cat <<EOF >version-patch.yaml
- op: add
  path: /spec/overrides
  value:
EOF
  for NAME in ${NAMES}
  do
    cat <<EOF >>version-patch.yaml
  - group: image.openshift.io/v1
    kind: ImageStream
    name: ${NAME}
    namespace: openshift
    unmanaged: true
EOF
  done
  oc patch clusterversion version --type json -p "$(cat version-patch.yaml)"

  for NAME in ${NAMES}
  do
    DIGEST="$(oc adm release info --image-for="${NAME}" | sed 's/.*@//')"
    cat <<EOF >image-stream-new-source.yaml
- op: replace
  path: /spec/tags/0/from
  value:
    kind: DockerImage
    name: "${MIRROR_BASE}@${DIGEST}"
EOF
    oc -n openshift patch imagestream "${NAME}" --type json -p "$(cat image-stream-new-source.yaml)"
  done
}

mkdir -p "${HOME}"

# wait for the API to come up
while true; do
    if [[ -f /tmp/shared/setup-failed ]]; then
      echo "Setup reported a failure, do not report test failure" 2>&1
      exit 0
    fi
    if [[ -f /tmp/shared/exit ]]; then
      echo "Another process exited" 2>&1
      exit 1
    fi
    if [[ ! -f /tmp/shared/setup-success ]]; then
      echo "Waiting for setup to finish..."
      sleep 15 & wait
      continue
    fi
    # don't let clients impact the global kubeconfig
    cp "${KUBECONFIG}" /tmp/shared/admin.kubeconfig
    export KUBECONFIG=/tmp/shared/admin.kubeconfig
    break
done

# if the cluster profile included an insights secret, install it to the cluster to
# report support data from the support-operator
if [[ -f /tmp/cluster/insights-live.yaml ]]; then
    oc create -f /tmp/cluster/insights-live.yaml || true
fi

# set up cloud-provider-specific env vars
KUBE_SSH_BASTION="$( oc --insecure-skip-tls-verify get node -l node-role.kubernetes.io/master -o 'jsonpath={.items[0].status.addresses[?(@.type=="ExternalIP")].address}' ):22"
export KUBE_SSH_BASTION
export KUBE_SSH_KEY_PATH=/tmp/cluster/ssh-privatekey

case "${CLUSTER_TYPE}" in
gcp)
    export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"
    export KUBE_SSH_USER=core
    mkdir -p ~/.ssh
    cp /tmp/cluster/ssh-privatekey ~/.ssh/google_compute_engine || true
    export TEST_PROVIDER='{"type":"gce","region":"us-east1","multizone": true,"multimaster":true,"projectid":"openshift-gce-devel-ci"}'
    ;;

aws)
  mkdir -p ~/.ssh
  cp /tmp/cluster/ssh-privatekey ~/.ssh/kube_aws_rsa || true
  export PROVIDER_ARGS="-provider=aws -gce-zone=us-east-1"
  # TODO: make openshift-tests auto-discover this from cluster config
  REGION="$(oc get -o jsonpath='{.status.platformStatus.aws.region}' infrastructure cluster)"
  ZONE="$(oc get -o jsonpath='{.items[0].metadata.labels.failure-domain\.beta\.kubernetes\.io/zone}' nodes)"
  export TEST_PROVIDER="{\"type\":\"aws\",\"region\":\"${REGION}\",\"zone\":\"${ZONE}\",\"multizone\":true,\"multimaster\":true}"
  export KUBE_SSH_USER=core
  ;;

azure4)
  export TEST_PROVIDER='azure'
  ;;

openstack)
	export TEST_PROVIDER='{"type":"openstack"}'
  ;;

openstack-vexxhost)
  export TEST_PROVIDER='{"type":"openstack"}'
  ;;
esac

# save the working dir because that's where our test script
# will be run from
cwd=$(pwd)
mkdir -p /tmp/output
cd /tmp/output

function setup_ssh_bastion() {
  export SSH_BASTION_NAMESPACE=test-ssh-bastion
  echo "Setting up ssh bastion"
  mkdir -p ~/.ssh
  cp "${KUBE_SSH_KEY_PATH}" ~/.ssh/id_rsa
  chmod 0600 ~/.ssh/id_rsa
  if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
      echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    fi
  fi
  curl https://raw.githubusercontent.com/eparis/ssh-bastion/master/deploy/deploy.sh | bash
  for ((i=0; i<=30; i++)); do
    # AWS fills only .hostname of a service
    BASTION_HOST=$(oc get service -n "${SSH_BASTION_NAMESPACE}" ssh-bastion -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    if [[ -n "${BASTION_HOST}" ]]; then break; fi
    # Azure fills only .ip of a service. Use it as bastion host.
    BASTION_HOST=$(oc get service -n "${SSH_BASTION_NAMESPACE}" ssh-bastion -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    if [[ -n "${BASTION_HOST}" ]]; then break; fi
    echo "Waiting for SSH bastion load balancer service"
    sleep 10
  done
  if [[ -z "${BASTION_HOST}" ]]; then
    echo "Failed to find bastion address, exiting"
    exit 1
  fi
  KUBE_SSH_BASTION="${BASTION_HOST}:22"
  export KUBE_SSH_BASTION
}

function setup-google-cloud-sdk() {
  pushd /tmp
  curl -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-256.0.0-linux-x86_64.tar.gz
  tar -xzf google-cloud-sdk-256.0.0-linux-x86_64.tar.gz
  export PATH=$PATH:/tmp/google-cloud-sdk/bin
  mkdir gcloudconfig
  export CLOUDSDK_CONFIG=/tmp/gcloudconfig
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project openshift-gce-devel-ci
  popd
}

function run-upgrade-tests() {
  openshift-tests run-upgrade "${TEST_SUITE}" --to-image "${IMAGE:-${RELEASE_IMAGE_LATEST}}" \
    --options "${TEST_OPTIONS:-}" \
    --provider "${TEST_PROVIDER:-}" -o "${ARTIFACT_DIR}/e2e.log" --junit-dir "${ARTIFACT_DIR}/junit"
}

function run-tests() {
  openshift-tests run "${TEST_SUITE}" \
    --provider "${TEST_PROVIDER:-}" -o "${ARTIFACT_DIR}/e2e.log" --junit-dir "${ARTIFACT_DIR}/junit"
}

if [[ "${CLUSTER_TYPE}" == "gcp" ]]; then
  setup-google-cloud-sdk
fi

cd "$cwd"
${TEST_COMMAND}
