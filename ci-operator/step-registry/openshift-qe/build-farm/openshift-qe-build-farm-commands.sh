#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
oc version
python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

ES_SECRETS_PATH=${ES_SECRETS_PATH:-/secret}

ES_HOST=${ES_HOST:-"search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"}
ES_PASSWORD=$(cat "${ES_SECRETS_PATH}/password")
ES_USERNAME=$(cat "${ES_SECRETS_PATH}/username")
if [ -e "${ES_SECRETS_PATH}/host" ]; then
    ES_HOST=$(cat "${ES_SECRETS_PATH}/host")
fi

REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
LATEST_TAG=$(git ls-remote --tags https://github.com/cloud-bulldozer/e2e-benchmarking.git | awk -F'refs/tags/' '{print $2}' | grep -v '\^{}' | sort -V | tail -n1)
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper
echo "mcornea patching rhcos version with cri-o 1.35.2-5.rhaos4.22 and wait"
oc apply -f- <<EOF
apiVersion: v1
items:
- apiVersion: machineconfiguration.openshift.io/v1
  kind: MachineConfig
  metadata:
    labels:
      machineconfiguration.openshift.io/role: worker
    name: os-layer-custom-worker
  spec:
    osImageURL: quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:81e97c192d3fed112c182dba8c4bbbbb6b1c15dfb3cf9ee4f3585267ba53ef16
- apiVersion: machineconfiguration.openshift.io/v1
  kind: MachineConfig
  metadata:
    labels:
      machineconfiguration.openshift.io/role: master
    name: os-layer-custom-master
  spec:
    osImageURL: quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:81e97c192d3fed112c182dba8c4bbbbb6b1c15dfb3cf9ee4f3585267ba53ef16
- apiVersion: machineconfiguration.openshift.io/v1
  kind: MachineConfig
  metadata:
    labels:
      machineconfiguration.openshift.io/role: infra
    name: os-layer-custom-infra
  spec:
    osImageURL: quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:81e97c192d3fed112c182dba8c4bbbbb6b1c15dfb3cf9ee4f3585267ba53ef16
kind: List
metadata:
  resourceVersion: ""
EOF
oc adm wait-for-stable-cluster --minimum-stable-period 5m

export WORKLOAD=build-farm

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"

if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    EXTRA_FLAGS+=" --local-indexing"
fi
EXTRA_FLAGS+="${BUILD_FARM_EXTRA_FLAGS} --gc-metrics=false --profile-type=${PROFILE_TYPE}"

if [[ -n "${USER_METADATA}" ]]; then
  echo "${USER_METADATA}" > user-metadata.yaml
  EXTRA_FLAGS+=" --user-metadata=user-metadata.yaml"
fi
export EXTRA_FLAGS
export ADDITIONAL_PARAMS

./run.sh

if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    metrics_folder_name=$(find . -maxdepth 1 -type d -name 'collected-metric*' | head -n 1)
    cp -r "${metrics_folder_name}" "${ARTIFACT_DIR}/"
fi
