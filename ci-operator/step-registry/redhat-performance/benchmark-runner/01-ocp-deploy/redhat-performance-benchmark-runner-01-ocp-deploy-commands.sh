#!/bin/bash

set -euo pipefail

# --- Step 01: OCP Deployment via JetLag ---
# Mirrors Jenkins 01-PerfCI-OpenShift-Deployment
# SSHes through jump host to cluster and runs the benchmark-runner
# container, which invokes JetLag to deploy OpenShift on bare-metal.

# SSH setup — two-hop: Prow → jump host → cluster
if [[ ! -s /secret/jh_priv_ssh_key ]] || [[ ! -s /secret/bastion_address ]]; then
  echo "ERROR: missing SSH credentials (jh_priv_ssh_key / bastion_address)" >&2
  exit 1
fi
cp /secret/jh_priv_ssh_key /tmp/provision_key
chmod 600 /tmp/provision_key

JUMPHOST=$(<"/secret/bastion_address")
JUMPHOST="${JUMPHOST%$'\n'}"
SSH_ARGS="-i /tmp/provision_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oServerAliveInterval=30 -oServerAliveCountMax=5"

CLUSTER_IP=""
[[ -s /secret/cluster_address ]] && CLUSTER_IP=$(<"/secret/cluster_address") && CLUSTER_IP="${CLUSTER_IP%$'\n'}"

# SCP RSA key to jump host for second hop
if [[ -s /secret/provision_private_key ]]; then
  scp ${SSH_ARGS} /secret/provision_private_key root@"${JUMPHOST}":/tmp/provision_private_key
else
  scp ${SSH_ARGS} /secret/jh_priv_ssh_key root@"${JUMPHOST}":/tmp/provision_private_key
fi
ssh ${SSH_ARGS} root@"${JUMPHOST}" "chmod 600 /tmp/provision_private_key"

if [[ -n "${CLUSTER_IP}" ]]; then
  REMOTE_SSH="ssh ${SSH_ARGS} root@${JUMPHOST} ssh -i /tmp/provision_private_key -oStrictHostKeyChecking=no root@${CLUSTER_IP}"
  PROVISION_IP="${CLUSTER_IP}"
else
  REMOTE_SSH="ssh ${SSH_ARGS} root@${JUMPHOST}"
  PROVISION_IP="${JUMPHOST}"
fi

QUAY_REPO="${QUAY_REPOSITORY}"

# Vault overrides for OCP version (Eli updates these per release cycle)
if [[ -s /secret/install_ocp_version ]]; then
  INSTALL_OCP_VERSION=$(<"/secret/install_ocp_version")
  INSTALL_OCP_VERSION="${INSTALL_OCP_VERSION%$'\n'}"
fi
if [[ -s /secret/ocp_build ]]; then
  OCP_BUILD=$(<"/secret/ocp_build")
  OCP_BUILD="${OCP_BUILD%$'\n'}"
fi

echo "=== Step 01: OCP Deployment ==="
echo "  OCP version: ${INSTALL_OCP_VERSION}"
echo "  OCP build:   ${OCP_BUILD}"
echo "  Timeout:     ${PROVISION_TIMEOUT}s"

# --- Cleanup previous deployments (on cluster) ---
echo "=== Cleanup: removing previous deployments ==="
${REMOTE_SSH} bash <<'CLEANUP_EOF'
set +e
curl -s http://localhost:8090/api/assisted-install/v2/clusters 2>/dev/null \
  | jq -r '.[].id' 2>/dev/null \
  | xargs -I % curl -s -X DELETE "http://localhost:8090/api/assisted-install/v2/clusters/%" 2>/dev/null

rm -rf /root/.ansible/tmp/

podman ps -q | xargs -r podman stop 2>/dev/null
podman ps -aq | xargs -r podman rm -f 2>/dev/null
podman pod ps -q | xargs -r podman pod rm -f 2>/dev/null
podman rmi -f -a 2>/dev/null
podman volume prune --force 2>/dev/null

rm -rf /opt/assisted-service /opt/http_store /opt/ocp-version

mkdir -p /root/.kube
touch /root/.kube/config
chmod 600 /root/.kube/config
echo "Cleanup complete"
CLEANUP_EOF

# --- Run JetLag deployment with retry (on cluster) ---
MAX_RETRIES=3
INSTALL_STEPS=("run_bare_metal_ocp_installer" "verify_bare_metal_install_complete")

for attempt in $(seq 1 "${MAX_RETRIES}"); do
  echo "=== Deployment attempt ${attempt}/${MAX_RETRIES} ==="
  deploy_failed=false

  for install_step in "${INSTALL_STEPS[@]}"; do
    echo "--- Running: ${install_step} ---"
    if ! ${REMOTE_SSH} \
      "podman run --rm \
        -e INSTALL_OCP_VERSION='${INSTALL_OCP_VERSION}' \
        -e OCP_BUILD='${OCP_BUILD}' \
        -e INSTALL_STEP='${install_step}' \
        -e PROVISION_IP='${PROVISION_IP}' \
        -e PROVISION_USER='root' \
        -e PROVISION_PORT='22' \
        -e KUBEADMIN_PASSWORD_PATH='/root/.kube/kubeadmin-password' \
        -e PROVISION_INSTALLER_PATH='/root/jetlag/./run_jetlag.sh' \
        -e PROVISION_INSTALLER_CMD='pushd /root/jetlag;/root/jetlag/./run_jetlag.sh 1>/dev/null 2>&1;popd' \
        -e PROVISION_INSTALLER_LOG='tail -100 /root/jetlag/jetlag.log' \
        -e INSTALLER_VAR_PATH='/root/jetlag/ansible/vars' \
        -e CONTAINER_PRIVATE_KEY_PATH='/root/.ssh/provision_private_key' \
        -e PROVISION_TIMEOUT='${PROVISION_TIMEOUT}' \
        -e log_level='INFO' \
        -v /root/.ssh/id_rsa:/root/.ssh/provision_private_key \
        -v /root/.kube/config:/root/.kube/config \
        --privileged '${QUAY_REPO}'"; then
      echo "--- FAILED: ${install_step} ---"
      deploy_failed=true
      break
    fi
    echo "--- Completed: ${install_step} ---"
  done

  if [[ "${deploy_failed}" == "false" ]]; then
    echo "=== Deployment succeeded on attempt ${attempt} ==="
    break
  fi

  if [[ ${attempt} -eq ${MAX_RETRIES} ]]; then
    echo "ERROR: Deployment failed after ${MAX_RETRIES} attempts" >&2
    ${REMOTE_SSH} "tail -100 /root/jetlag/jetlag.log 2>/dev/null || true"
    exit 1
  fi

  echo "=== Retrying after cleanup... ==="
  ${REMOTE_SSH} bash <<'RETRY_CLEANUP_EOF'
set +e
podman ps -q | xargs -r podman stop 2>/dev/null
podman ps -aq | xargs -r podman rm -f 2>/dev/null
podman rmi -f -a 2>/dev/null
RETRY_CLEANUP_EOF
done

# --- Export kubeconfig and kubeadmin-password to SHARED_DIR ---
echo "=== Copying cluster credentials to SHARED_DIR ==="
${REMOTE_SSH} "cat /root/.kube/config" > "${SHARED_DIR}/kubeconfig"
${REMOTE_SSH} "cat /root/.kube/kubeadmin-password" > "${SHARED_DIR}/kubeadmin_password"

echo "=== Step 01 complete: OCP deployed, credentials in SHARED_DIR ==="
