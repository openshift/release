#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR
# Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' TERM ERR

[ -z "${AUX_HOST}" ] && { echo "\$AUX_HOST is not filled. Failing."; exit 1; }
[ -z "${architecture}" ] && { echo "\$architecture is not filled. Failing."; exit 1; }
[ -z "${workers}" ] && { echo "\$workers is not filled. Failing."; exit 1; }
[ -z "${masters}" ] && { echo "\$masters is not filled. Failing."; exit 1; }

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

function oinst() {
  /tmp/openshift-install --dir="${INSTALL_DIR}" --log-level=debug "${@}" 2>&1 | grep\
   --line-buffered -v 'password\|X-Auth-Token\|UserData:'
}

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

BASE_DOMAIN=$(<"${CLUSTER_PROFILE_DIR}/base_domain")
PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
INSTALL_DIR="/tmp/installer"
API_VIP="$(yq ".api_vip" "${SHARED_DIR}/vips.yaml")"
INGRESS_VIP="$(yq ".ingress_vip" "${SHARED_DIR}/vips.yaml")"
mkdir -p "${INSTALL_DIR}"

echo "Installing from initial release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
oc adm release extract -a "$PULL_SECRET_PATH" "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
   --command=openshift-install --to=/tmp

if [ "${DISCONNECTED}" == "true" ]; then
  OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="$(<"${CLUSTER_PROFILE_DIR}/mirror_registry_url")/${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE#*/}"
fi

# Patching the cluster_name again as the one set in the ipi-conf ref is using the ${UNIQUE_HASH} variable, and
# we might exceed the maximum length for some entity names we define
# (e.g., hostname, NFV-related interface names, etc...)
CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")
[ -f "${SHARED_DIR}/install-config.yaml" ] || echo "{}" >> "${SHARED_DIR}/install-config.yaml"
yq --inplace eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$SHARED_DIR/install-config.yaml" - <<< "
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
networking:
  machineNetwork:
  - cidr: ${INTERNAL_NET_CIDR}
controlPlane:
   architecture: ${architecture}
   hyperthreading: Enabled
   name: master
   replicas: ${masters}
"

if [ "${masters}" -eq 1 ]; then
  yq --inplace eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$SHARED_DIR/install-config.yaml" - <<< "
platform:
  none: {}
compute:
- architecture: ${architecture}
  hyperthreading: Enabled
  name: worker
  replicas: 0
"
fi

if [ "${masters}" -gt 1 ]; then
  yq --inplace eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$SHARED_DIR/install-config.yaml" - <<< "
compute:
- architecture: ${architecture}
  hyperthreading: Enabled
  name: worker
  replicas: ${workers}
platform:
  baremetal:
    hosts: []
    apiVIPs:
    - ${API_VIP}
    ingressVIPs:
    - ${INGRESS_VIP}
"
  echo "[INFO] Processing the platform.baremetal.hosts list in the install-config.yaml..."
  # shellcheck disable=SC2154
  for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
    # shellcheck disable=SC1090
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
    ADAPTED_YAML="
    name: ${name}
    role: ${name%%-[0-9]*}
    bootMACAddress: ${mac}
  "

    # Patch the install-config.yaml by adding the given host to the hosts list in the platform.baremetal stanza
    yq --inplace eval-all 'select(fileIndex == 0).platform.baremetal.hosts += select(fileIndex == 1) | select(fileIndex == 0)' \
      "$SHARED_DIR/install-config.yaml" - <<< "$ADAPTED_YAML"
  done
fi

# From now on, we assume no more patches to the install-config.yaml are needed.
# Also, we assume that the agent-config.yaml is already in place in the SHARED_DIR.
# We can create the installation dir with the install-config.yaml and agent-config.yaml.
grep -v "password\|username\|pullSecret" "${SHARED_DIR}/install-config.yaml" > "${ARTIFACT_DIR}/install-config.yaml" || true

grep -v "password\|username\|pullSecret" "${SHARED_DIR}/agent-config.yaml" > "${ARTIFACT_DIR}/agent-config.yaml" || true
grep -v "password\|username\|pullSecret" "${SHARED_DIR}/agent-config-unconfigured.yaml" > "${ARTIFACT_DIR}/agent-config-unconfigured.yaml" || true

echo -e "\nPreparing minimal config YAML files for unconfigured ignition"

cp "${SHARED_DIR}/install-config.yaml" "${INSTALL_DIR}/"
cp "${SHARED_DIR}/agent-config-unconfigured.yaml" "${INSTALL_DIR}/agent-config.yaml"

echo -e "\nCreating unconfigured ignition..."
oinst agent create unconfigured-ignition

echo -e "\nCopy ignition file to shared dir..."

cp "${INSTALL_DIR}/${UNCONFIGURED_AGENT_IGNITION_FILENAME}" "${SHARED_DIR}/"

echo -e "\nCopy ignition file to artifact dir..."

cp "${INSTALL_DIR}/${UNCONFIGURED_AGENT_IGNITION_FILENAME}" "${ARTIFACT_DIR}/"

cp "${SHARED_DIR}/install-config.yaml" "${INSTALL_DIR}/"
cp "${SHARED_DIR}/agent-config.yaml" "${INSTALL_DIR}/"

echo -e "\nCreating agent image and CoreOS cache..."
oinst agent create image

### Copy the CoreOS image to the auxiliary host, it will be used to generate the unconfigured agent image
echo -e "\nCopying the CoreOS ISO image into the bastion host..."
scp "${SSHOPTS[@]}" "${CACHED_COREOS_IMAGE_PATH}" "root@${AUX_HOST}:/opt/html/${CLUSTER_NAME}/${COREOS_IMAGE_NAME}"
