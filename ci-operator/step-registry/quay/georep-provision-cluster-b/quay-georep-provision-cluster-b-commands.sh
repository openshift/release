#!/bin/bash
set -euo pipefail

# Provision a second IPI OCP cluster in the secondary region for Quay
# geo-replication testing. Extracts openshift-install from the release
# payload used by cluster A, generates an install-config for the
# secondary region, and runs the installer.
#
# This script does not enable set -x to avoid leaking credentials.

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}/quay-georep-provision-cluster-b"
mkdir -p "${ARTIFACT_DIR}"

REGION_SECONDARY="${QUAY_GEOREP_REGION_SECONDARY:-us-west-2}"
NODE_COUNT="${QUAY_GEOREP_CLUSTER_B_NODE_COUNT:-3}"

QUAY_AWS_ACCESS_KEY="$(cat /var/run/quay-qe-aws-secret/access_key)"
QUAY_AWS_SECRET_KEY="$(cat /var/run/quay-qe-aws-secret/secret_key)"
export AWS_ACCESS_KEY_ID="${QUAY_AWS_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${QUAY_AWS_SECRET_KEY}"

PULL_SECRET="${CLUSTER_PROFILE_DIR}/pull-secret"
SSH_PUB_KEY_FILE="${CLUSTER_PROFILE_DIR}/ssh-publickey"
BASE_DOMAIN="${QUAY_GEOREP_BASE_DOMAIN:-quayqe.devcluster.openshift.com}"

CLUSTER_NAME="georep-b-${NAMESPACE:-ns}-${UNIQUE_HASH:-$(date +%s)}"
CLUSTER_NAME="$(printf '%s' "${CLUSTER_NAME}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | cut -c1-27)"

# Use /tmp for the install directory — SHARED_DIR is backed by a
# Kubernetes Secret (~1 MiB limit) and the install state is too large.
INSTALL_DIR="/tmp/cluster-b-install"
mkdir -p "${INSTALL_DIR}"

RELEASE_IMAGE="${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}"
if [[ -z "${RELEASE_IMAGE}" ]]; then
    echo "ERROR: OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is not set" >&2
    exit 1
fi

echo "Extracting openshift-install from release image..." >&2
oc adm release extract -a "${PULL_SECRET}" "${RELEASE_IMAGE}" \
    --command=openshift-install --to="${INSTALL_DIR}"
INSTALLER="${INSTALL_DIR}/openshift-install"
chmod +x "${INSTALLER}"
echo "Installer version:" >&2
"${INSTALLER}" version >&2

SSH_PUB_KEY=""
if [[ -r "${SSH_PUB_KEY_FILE}" ]]; then
    SSH_PUB_KEY="$(cat "${SSH_PUB_KEY_FILE}")"
fi

PULL_SECRET_CONTENT="$(cat "${PULL_SECRET}")"

cat >"${INSTALL_DIR}/install-config.yaml" <<EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
platform:
  aws:
    region: ${REGION_SECONDARY}
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform:
    aws:
      type: m5.2xlarge
  replicas: ${NODE_COUNT}
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform:
    aws:
      type: m5.xlarge
  replicas: 3
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
publish: External
pullSecret: '${PULL_SECRET_CONTENT}'
sshKey: |
  ${SSH_PUB_KEY}
EOF

grep -v "password\|username\|pullSecret\|auth" "${INSTALL_DIR}/install-config.yaml" \
    > "${ARTIFACT_DIR}/install-config.yaml.bak"

# Save metadata early so the deprovision step can clean up partial installs.
# metadata.json is created by the installer before provisioning starts.
function save_metadata() {
    if [[ -s "${INSTALL_DIR}/metadata.json" ]]; then
        cp "${INSTALL_DIR}/metadata.json" "${SHARED_DIR}/cluster-b-metadata.json"
    fi
}

printf '%s' "${CLUSTER_NAME}" > "${SHARED_DIR}/QUAY_GEOREP_CLUSTER_B_NAME"
printf '%s' "${REGION_SECONDARY}" > "${SHARED_DIR}/QUAY_GEOREP_CLUSTER_B_REGION"
printf '%s' "${RELEASE_IMAGE}" > "${SHARED_DIR}/QUAY_GEOREP_CLUSTER_B_RELEASE_IMAGE"

echo "Creating cluster '${CLUSTER_NAME}' in ${REGION_SECONDARY}..." >&2
if ! "${INSTALLER}" create cluster --dir="${INSTALL_DIR}" --log-level=info 2>&1 | tee "${ARTIFACT_DIR}/install.log"; then
    echo "ERROR: openshift-install create cluster failed" >&2
    save_metadata
    cp "${INSTALL_DIR}"/.openshift_install_state.json "${ARTIFACT_DIR}/" 2>/dev/null || true
    exit 1
fi

echo "Cluster B provisioned successfully in ${REGION_SECONDARY}" >&2

save_metadata
cp "${INSTALL_DIR}/auth/kubeconfig" "${SHARED_DIR}/kubeconfig-cluster-b"
chmod 600 "${SHARED_DIR}/kubeconfig-cluster-b"

echo "Cluster B name: ${CLUSTER_NAME}" >&2
echo "Region: ${REGION_SECONDARY}" >&2
echo "Kubeconfig: \${SHARED_DIR}/kubeconfig-cluster-b" >&2

KUBECONFIG="${SHARED_DIR}/kubeconfig-cluster-b" oc get nodes >&2 || true
