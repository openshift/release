#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECTL=oc
export IMG="${INSTASLICE_CONTROLLER_IMG}"
export IMG_DMST="${INSTASLICE_DAEMONSET_IMG}"

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

echo "Deploying cert-manager-operator for ocp"
make deploy-cert-manager-ocp
echo "Deploying node feature discovery nfd-operator for ocp"
make deploy-nfd-ocp
echo "Deploying nvidia-gpu-operator for ocp"
make deploy-nvidia-ocp
echo "Creating OperatorGroup"
oc get ns instaslice-system || oc create ns instaslice-system
oc create -f - <<EOF
    apiVersion: operators.coreos.com/v1
    kind: OperatorGroup
    metadata:
        name: "instaslice"
        namespace: "instaslice-system"
EOF
sleep 30

# (TODO) Remove the following piece of code along with the above binary downloading
# when the Makefile is modified to use vendored binaries
echo "   creating instaslice-operator manifests"
controller-gen rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases
rm -rf bundle-ocp/manifests && mkdir bundle-ocp/manifests
kustomize build --load-restrictor LoadRestrictionsNone config/manifests-ocp | sed -e "s|containerImage: .*|containerImage: $IMG|g" |sed -e "s|image:.*instaslice-rhel9-operator.*|image: $IMG|g" | sed -e "s|value: .*instaslice-daemonset-rhel9.*|value: $IMG_DMST|g" > bundle-ocp/manifests/kustomize.yaml
echo "   deploy instaslice-operator"
oc apply -f bundle-ocp/manifests/kustomize.yaml || true

echo "Running e2e tests"
make test-e2e-ocp
