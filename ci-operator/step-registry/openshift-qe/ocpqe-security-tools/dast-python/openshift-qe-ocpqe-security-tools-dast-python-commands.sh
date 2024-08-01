#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
python3 --version
pushd /tmp

ls

git clone https://github.com/paigerube14/ocpqe-security-tools.git --branch main --depth 1

ls

ls ocpqe-security-tools/dast

oc login -u kubeadmin -p "$(cat $SHARED_DIR/kubeadmin-password)"

export NAMESPACE=default 
export CONSOLE_URL=$(oc get routes console -n openshift-console -o jsonpath='{.spec.host}')
export CLUSTER_NAME=$(oc get machineset -n openshift-machine-api -o=go-template='{{(index (index .items 0).metadata.labels "machine.openshift.io/cluster-api-cluster" )}}')
export BASE_API_URL=$(oc get infrastructure -o jsonpath="{.items[*].status.apiServerURL}")
export TOKEN=$(oc whoami -t)
export NAMESPACE=${NAMESPACE:-default}

oc label ns $NAMESPACE security.openshift.io/scc.podSecurityLabelSync=false pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite
mkdir results

if [[ "$api_doc" == *"/"* ]]; then
    export API_URL="$BASE_API_URL/openapi/v3/apis/$api_doc"
else   # e.g. 'v1'
    export API_URL="$BASE_API_URL/openapi/v3/api/$api_doc"
fi
  
envsubst < ocpqe-security-tools/dast/config.yaml.template > config.yaml

cat config.yaml

python rapidast.py --config config.yaml

ls

mkdir -p "${ARTIFACT_DIR}/rapidast_results"

cp -rpv "./results/"** "${ARTIFACT_DIR}/rapidast_results" 2>/dev/null
