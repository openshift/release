#!/bin/bash

export KUBECTL=oc
export BUNDLE_IMG=quay.io/redhat-user-workloads/dynamicacceleratorsl-tenant/instaslice-operator-bundle:on-pr-${PULL_NUMBER}

# Install tools
TOOLS_DIR=/tmp/bin
mkdir -p "${TOOLS_DIR}"
export PATH="${TOOLS_DIR}:${PATH}"

echo "## Install umoci"
curl -L --retry 5 https://github.com/opencontainers/umoci/releases/download/v0.4.7/umoci.amd64 -o "${TOOLS_DIR}/umoci" && chmod +x "${TOOLS_DIR}/umoci"
echo "   umoci installed"

echo "Waiting for image ${BUNDLE_IMG} to be available..."
function wait_for_image() {
    until skopeo inspect docker://${BUNDLE_IMG} >/dev/null 2>&1; do
	echo "Image not found yet. Retrying in 30s..."
        sleep 30
    done
}

export -f wait_for_image
timeout 25m bash -c "wait_for_image"

oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: instaslice-registry
spec:
  imageTagMirrors:
  - mirrors:
      - quay.io/redhat-user-workloads/dynamicacceleratorsl-tenant/instaslice-operator
    source: registry.redhat.io/dynamic-accelerator-slicer-tech-preview/instaslice-rhel9-operator
  - mirrors:
      - quay.io/redhat-user-workloads/dynamicacceleratorsl-tenant/instaslice-daemonset
    source: registry.redhat.io/dynamic-accelerator-slicer-tech-preview/instaslice-daemonset-rhel9
EOF

oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: instaslice-registry
spec:
  imageDigestMirrors:
    - mirrors:
      - quay.io/redhat-user-workloads/dynamicacceleratorsl-tenant/instaslice-operator
    source: registry.redhat.io/dynamic-accelerator-slicer-tech-preview/instaslice-rhel9-operator
    - mirrors:
      - quay.io/redhat-user-workloads/dynamicacceleratorsl-tenant/instaslice-daemonset
    source: registry.redhat.io/dynamic-accelerator-slicer-tech-preview/instaslice-daemonset-rhel9
EOF

echo "Image is available. Proceeding with tests..."

make deploy-cert-manager-ocp
make deploy-nfd-ocp
make deploy-nvidia-ocp

mkdir /tmp/oci-image && pushd /tmp/oci-image
skopeo copy docker://${BUNDLE_IMG} oci:instaslice-operator-bundle:pr
umoci unpack --rootless --image ./instaslice-operator-bundle:pr bundle/
oc create -f bundle/rootfs/manifests || true
popd

echo "Creating OperatorGroup"
oc create -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "instaslice"
  namespace: "instaslice-system"
EOF
