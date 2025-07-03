#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECTL=oc
export IMAGE_REGISTRY="${IMAGE_REGISTRY}"
export IMAGE_TAG="${IMAGE_TAG}"
export OPERATOR_IMG="${DAS_OPERATOR_IMG}"
export DAEMONSET_IMG="${DAS_DAEMONSET_IMG}"
export SCHEDULER_IMG="${DAS_SCHEDULER_IMG}"
export WEBHOOK_IMG="${DAS_WEBHOOK_IMG}"
export EMULATED_MODE="disabled"
export DEPLOY_DIR=deploy
export TMP_DIR=$(mktemp -d)

TOOLS_DIR=/tmp/bin
CONTROLLER_GEN_VERSION=v0.16.4
KUSTOMIZE_VERSION=v5.4.1
KUSTOMIZE_TAR="kustomize_${KUSTOMIZE_VERSION}_$(go env GOOS)_$(go env GOARCH).tar.gz"
JQ_VERSION=jq-1.7
JQ_BINARY_URL="https://github.com/jqlang/jq/releases/download/${JQ_VERSION}/jq-$(go env GOOS)-$(go env GOARCH)"

# Install tools
echo "Installing tools to deploy instaslice-operator"
mkdir -p "${TOOLS_DIR}"
curl -L --retry 5 \
"https://github.com/kubernetes-sigs/controller-tools/releases/download/${CONTROLLER_GEN_VERSION}/controller-gen-$(go env GOOS)-$(go env GOARCH)" \
-o "${TOOLS_DIR}/controller-gen" && chmod +x "${TOOLS_DIR}/controller-gen"
echo "   controller-gen installed"
curl -L --retry 5 \
"https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/${KUSTOMIZE_TAR}" \
-o kustomize.tar.gz
tar -xzf kustomize.tar.gz -C "${TOOLS_DIR}"
rm kustomize.tar.gz
chmod +x "${TOOLS_DIR}/kustomize"
echo "   kustomize installed"
curl -L --retry 5 "${JQ_BINARY_URL}" -o "${TOOLS_DIR}/jq" && chmod +x "${TOOLS_DIR}/jq"
echo "   jq installed"
export PATH="${TOOLS_DIR}:${PATH}"

echo "Adding the required labels to the node"
NODES=$($KUBECTL get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}')
$KUBECTL label node $NODES nvidia.com/mig.capable=true --overwrite

make regen-crd-k8s
$KUBECTL apply -f ${DEPLOY_DIR}/00_instaslice-operator.crd.yaml -f ${DEPLOY_DIR}/00_nodeaccelerators.crd.yaml
$KUBECTL wait --for=condition=established --timeout=60s crd dasoperators.inference.redhat.com
cp ${DEPLOY_DIR}/*.yaml ${TMP_DIR}/
sed -i 's/emulatedMode: .*/emulatedMode: "$(EMULATED_MODE)"/' ${TMP_DIR}/03_instaslice_operator.cr.yaml
sed "s|\${IMAGE_REGISTRY}|$IMAGE_REGISTRY|g; s|\${IMAGE_TAG}|$IMAGE_TAG|g" "${DEPLOY_DIR}/04_deployment.yaml" > "${TMP_DIR}/04_deployment.yaml"
sed "s|\${IMAGE_REGISTRY}|$IMAGE_REGISTRY|g; s|\${IMAGE_TAG}|$IMAGE_TAG|g" "${DEPLOY_DIR}/05_scheduler_deployment.yaml" > "${TMP_DIR}/05_scheduler_deployment.yaml"
#env IMAGE_REGISTRY="${IMAGE_REGISTRY}" IMAGE_TAG="${IMAGE_TAG}" envsubst < ${DEPLOY_DIR}/04_deployment.yaml > $$TMP_DIR/04_deployment.yaml
#env IMAGE_REGISTRY="${IMAGE_REGISTRY}" IMAGE_TAG="${IMAGE_TAG}" envsubst < ${DEPLOY_DIR}/05_scheduler_deployment.yaml > $$TMP_DIR/05_scheduler_deployment.yaml
$KUBECTL apply -f ${TMP_DIR}/
$KUBECTL apply -f ${TMP_DIR}/05_scheduler_deployment.yaml


echo "Running e2e tests"
make test-e2e
