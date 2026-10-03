#!/bin/bash

set -euo pipefail

# --- Step 02: Operators Deployment ---
# Mirrors Jenkins 02-PerfCI-Operators-Deployment
# SSHes to cluster and installs CNV, LSO, ODF, Infra, Custom operators
# via the benchmark-runner container.

# SSH setup: direct (cluster_address) primary, bastion fallback
if [[ -s /secret/cluster_address ]] && [[ -s /secret/provision_private_key ]]; then
  CLUSTER_IP=$(<"/secret/cluster_address")
  CLUSTER_IP="${CLUSTER_IP%$'\n'}"
  cp /secret/provision_private_key /tmp/cluster_key
  chmod 600 /tmp/cluster_key
  SSH_ARGS="-i /tmp/cluster_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oServerAliveInterval=30 -oServerAliveCountMax=5"
elif [[ -s /secret/bastion_address ]] && [[ -s /secret/jh_priv_ssh_key ]]; then
  CLUSTER_IP=$(<"/secret/bastion_address")
  CLUSTER_IP="${CLUSTER_IP%$'\n'}"
  cp /secret/jh_priv_ssh_key /tmp/cluster_key
  chmod 600 /tmp/cluster_key
  SSH_ARGS="-i /tmp/cluster_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oServerAliveInterval=30 -oServerAliveCountMax=5"
else
  echo "ERROR: need cluster_address+provision_private_key or bastion_address+jh_priv_ssh_key" >&2
  exit 1
fi

REMOTE_SSH="ssh ${SSH_ARGS} root@${CLUSTER_IP}"
PROVISION_IP="${CLUSTER_IP}"

QUAY_REPO="${QUAY_REPOSITORY}"

echo "=== Step 02: Operators Deployment ==="
echo "  CNV: ${CNV_VERSION}  LSO: ${LSO_VERSION}  ODF: ${ODF_VERSION}"

# Get kubeadmin password from cluster → Vault fallback
KUBEADMIN_PASSWORD=$(${REMOTE_SSH} "cat /root/.kube/kubeadmin-password 2>/dev/null" || true)
KUBEADMIN_PASSWORD="${KUBEADMIN_PASSWORD%$'\n'}"
if [[ -z "${KUBEADMIN_PASSWORD}" ]] && [[ -s /secret/kubeadmin_password ]]; then
  KUBEADMIN_PASSWORD=$(<"/secret/kubeadmin_password")
  KUBEADMIN_PASSWORD="${KUBEADMIN_PASSWORD%$'\n'}"
fi
if [[ -z "${KUBEADMIN_PASSWORD}" ]]; then
  echo "ERROR: could not read kubeadmin-password" >&2
  exit 1
fi

# Fresh oc login on cluster
CLUSTER_API=$(${REMOTE_SSH} "grep server /root/.kube/config 2>/dev/null | head -1 | awk '{print \$2}'" || true)
CLUSTER_API="${CLUSTER_API%$'\n'}"
CLUSTER_API="${CLUSTER_API// /}"
if [[ -n "${CLUSTER_API}" ]]; then
  echo "Logging into cluster: ${CLUSTER_API}"
  ${REMOTE_SSH} "oc login '${CLUSTER_API}' -u kubeadmin -p '${KUBEADMIN_PASSWORD}' --insecure-skip-tls-verify 2>&1 | tail -1"
  ${REMOTE_SSH} "CLUSTER_NAME=\$(oc config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null); [ -n \"\${CLUSTER_NAME}\" ] && oc config set-cluster \"\${CLUSTER_NAME}\" --insecure-skip-tls-verify=true >/dev/null"
fi

# Read Vault secrets
WORKER_DISK_IDS=""
[[ -s /secret/worker_disk_ids ]] && WORKER_DISK_IDS=$(<"/secret/worker_disk_ids") && WORKER_DISK_IDS="${WORKER_DISK_IDS%$'\n'}"
EXPECTED_NODES=""
[[ -s /secret/expected_nodes ]] && EXPECTED_NODES=$(<"/secret/expected_nodes") && EXPECTED_NODES="${EXPECTED_NODES%$'\n'}"

# --- CNV Nightly Registration (on cluster) ---
if [[ ! "${CNV_VERSION}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: CNV_VERSION contains invalid characters: ${CNV_VERSION}" >&2
  exit 1
fi
if [[ ! -s /secret/cnv_nightly_registered ]] || [[ ! -s /secret/cnv_nightly_catalog_source ]]; then
  echo "ERROR: missing required Vault secrets: cnv_nightly_registered / cnv_nightly_catalog_source" >&2
  exit 1
fi
echo "=== Applying CNV nightly catalog source ==="
scp ${SSH_ARGS} /secret/cnv_nightly_registered root@"${CLUSTER_IP}":/tmp/cnv_registered.sh
scp ${SSH_ARGS} /secret/cnv_nightly_catalog_source root@"${CLUSTER_IP}":/tmp/catalog_source.yaml

${REMOTE_SSH} "export CNV_VERSION='${CNV_VERSION}'; bash -s" <<'NIGHTLY_EOF'
chmod +x /tmp/cnv_registered.sh
/tmp/cnv_registered.sh
sed -i "s/{{ cnv_version }}/${CNV_VERSION}/g" /tmp/catalog_source.yaml
export KUBECONFIG=/root/.kube/config
oc apply -f /tmp/catalog_source.yaml
rm -f /tmp/cnv_registered.sh /tmp/catalog_source.yaml
NIGHTLY_EOF
echo "=== CNV nightly catalog applied ==="

# --- Copy SSH key to cluster for podman container mount ---
if [[ -s /secret/provision_private_key ]]; then
  scp ${SSH_ARGS} /secret/provision_private_key root@"${CLUSTER_IP}":/tmp/provision_private_key
else
  scp ${SSH_ARGS} /tmp/cluster_key root@"${CLUSTER_IP}":/tmp/provision_private_key
fi
${REMOTE_SSH} "chmod 600 /tmp/provision_private_key"

# --- Install operators sequentially (on cluster) ---
# CNV first: creates "-virtualization" storage class needed for Windows bootstorm
OPERATORS=("cnv" "lso" "odf" "infra" "custom")

QUOTED_EXPECTED_NODES=$(printf '%q' "${EXPECTED_NODES}")
QUOTED_WORKER_DISK_IDS=$(printf '%q' "${WORKER_DISK_IDS}")

for operator in "${OPERATORS[@]}"; do
  echo "=== Installing operator: ${operator} ==="
  ${REMOTE_SSH} \
    "podman run --rm \
      -e INSTALL_OCP_RESOURCES='True' \
      -e INSTALL_RESOURCES_LIST='${operator}' \
      -e EXPECTED_NODES=${QUOTED_EXPECTED_NODES} \
      -e CNV_VERSION='${CNV_VERSION}' \
      -e LSO_VERSION='${LSO_VERSION}' \
      -e ODF_VERSION='${ODF_VERSION}' \
      -e NUM_ODF_DISK='${NUM_ODF_DISK}' \
      -e KUBEADMIN_PASSWORD='${KUBEADMIN_PASSWORD}' \
      -e PROVISION_IP='${PROVISION_IP}' \
      -e CONTAINER_PRIVATE_KEY_PATH='/root/.ssh/provision_private_key' \
      -e PROVISION_USER='root' \
      -e PROVISION_PORT='22' \
      -e WORKER_DISK_IDS=${QUOTED_WORKER_DISK_IDS} \
      -e WORKER_DISK_PREFIX='${WORKER_DISK_PREFIX}' \
      -e PROVISION_TIMEOUT='${PROVISION_TIMEOUT}' \
      -e log_level='INFO' \
      -v /tmp/provision_private_key:/root/.ssh/provision_private_key \
      -v /root/.kube/config:/root/.kube/config \
      --privileged '${QUAY_REPO}'"
  echo "=== Completed: ${operator} ==="
done

# --- Cleanup container images on cluster ---
${REMOTE_SSH} "export QUAY_REPO='${QUAY_REPO}'; bash -s" <<'CLEANUP_EOF'
set +e
containers=$(podman ps -a --filter "ancestor=${QUAY_REPO}" -q)
[ -n "$containers" ] && podman stop $containers && podman rm -f $containers
podman rmi -f "${QUAY_REPO}" 2>/dev/null
CLEANUP_EOF

echo "=== Step 02 complete: all operators installed ==="
