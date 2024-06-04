#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

git clone $DAST_TOOL_URL --branch $DAST_TOOL_BRANCH --depth 1


git clone https://github.com/paigerube14/ocp-qe-perfscale-ci.git --branch ssml --depth 1

DAST_PATH

ls

oc login -u kubeadmin -p $KUBEADMIN_PASSWORD_FILE
HELM_DIR=$(mktemp -d)
curl -sS -L https://get.helm.sh/helm-v3.11.2-linux-amd64.tar.gz | tar -xzC ${HELM_DIR}/ linux-amd64/helm

${HELM_DIR}/linux-amd64/helm version  

mv ${HELM_DIR}/linux-amd64/helm $WORKSPACE/helm
PATH=$PATH:$WORKSPACE
helm version
pushd ocp-qe-perfscale-ci
./deploy_ssml_api.sh