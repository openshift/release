#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR

OVE_ISO_STORAGE_HOST=$(<"${CLUSTER_PROFILE_DIR}/ove_iso_storage_host")

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'TCPKeepAlive=yes'
  -o 'ServerAliveInterval=30'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")
SSH_KEY=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")

CONTAINER_NAME="haproxy-$(<"${SHARED_DIR}"/cluster_name)"
BASE_DOMAIN=$(<"${CLUSTER_PROFILE_DIR}/base_domain")

if [ "${PATCH_STATIC_NETWORK:-false}" = true ]; then
  [ -z "${architecture}" ] && { echo "\$architecture is not filled. Failing."; exit 1; }
  [ -z "${workers}" ] && { echo "\$workers is not filled. Failing."; exit 1; }
  [ -z "${masters}" ] && { echo "\$masters is not filled. Failing."; exit 1; }

  CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")
  [ -f "${SHARED_DIR}/install-config.yaml" ] || echo "{}" >> "${SHARED_DIR}/install-config.yaml"
  yq --inplace eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$SHARED_DIR/install-config.yaml" - <<< "
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
controlPlane:
   architecture: ${architecture}
   hyperthreading: Enabled
   name: master
   replicas: ${masters}
compute:
- architecture: ${architecture}
  hyperthreading: Enabled
  name: worker
  replicas: ${workers}
"

  echo "[INFO] Looking for patches to the install-config.yaml..."

  shopt -s nullglob
  for f in "${SHARED_DIR}"/*_patch_install_config.yaml;
  do
    if test -f "${f}"
    then
        echo "[INFO] Applying patch file: $f"
        yq --inplace eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$SHARED_DIR/install-config.yaml" "$f"
    fi
  done

  echo "[INFO] Looking for patches to the agent-config.yaml..."

  shopt -s nullglob
  for f in "${SHARED_DIR}"/*_patch_agent_config.yaml;
  do
    if test -f "${f}"
    then
        echo "[INFO] Applying patch file: $f"
        yq --inplace eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$SHARED_DIR/agent-config.yaml" "$f"
    fi
  done

  INSTALL_CONFIG=$(base64 -w 0 "${SHARED_DIR}/install-config.yaml")
  AGENT_CONFIG=$(base64 -w 0 "${SHARED_DIR}/agent-config.yaml")
  AGENT_ISO="${CLUSTER_NAME}.agent-ove.x86_64.iso"
  timeout -s 9 10m ssh "${SSHOPTS[@]}" root@"${AUX_HOST}" \
    "nsenter -n -t \"\$(podman inspect -f '{{ .State.Pid }}' \"${CONTAINER_NAME}\")\" \
     ssh -o StrictHostKeyChecking=no root@\"${OVE_ISO_STORAGE_HOST}\" sh /tmp/patch_static \
      \"${AGENT_ISO}\" \"${INSTALL_CONFIG}\" \"${AGENT_CONFIG}\""
fi

timeout -s 9 10m ssh "${SSHOPTS[@]}" root@"${AUX_HOST}" \
  "nsenter -n -t \"\$(podman inspect -f '{{ .State.Pid }}' \"${CONTAINER_NAME}\")\" \
   ssh -o StrictHostKeyChecking=no root@\"${OVE_ISO_STORAGE_HOST}\" patch_ove_iso_ignition_file.sh \
    \"${AGENT_ISO}\" \"${SSH_KEY}\""