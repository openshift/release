#!/bin/bash

#
# Step to customize installer manifests required by Platform External for each platform.
# The step creates manifests (openshift-install create manifests) and generate the ignition
# config files (create ignition-configs), saving in a the shared storage.
#

set -o nounset
set -o errexit
set -o pipefail

echo "Using release image ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

STEP_WORKDIR=${STEP_WORKDIR:-/tmp}
INSTALL_DIR=${STEP_WORKDIR}/install-dir
mkdir -vp "${INSTALL_DIR}"

source "${SHARED_DIR}/init-fn.sh" || true

log "Copying to install dir"
cp -vp "${SHARED_DIR}"/install-config.yaml "${INSTALL_DIR}"/install-config.yaml

# Extracting openshift-install from the release image.
# This is necessary to avoid using the upi-installer binary, which is not available in the release image,
# and to ensure manifests will be created with the installed binary instead
# of the step image binary.
export INSTALLER_BINARY="openshift-install"
if [[ -n "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}" ]]; then
  # Build-farm release images (registry.build*.ci.openshift.org) need CI registry credentials on
  # top of the cluster-profile pull secret. platform-external-pre-conf already builds such a file
  # when it runs; fall back to logging in ourselves so this step does not depend on step ordering.
  PULL_SECRET="${SHARED_DIR}/pull-secret-with-ci"
  if [[ ! -s "${PULL_SECRET}" ]]; then
    PULL_SECRET="/tmp/pull-secret-with-ci"
    cp -f "${CLUSTER_PROFILE_DIR}/pull-secret" "${PULL_SECRET}"
    if [[ "$(dirname "$(dirname "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}")")" != "quay.io" ]]; then
      KUBECONFIG="" oc registry login --to "${PULL_SECRET}"
    fi
  fi

  CONTAINER_VERSION="$(${INSTALLER_BINARY} version | awk '/^openshift-install/ {print $2; exit}' | cut -d. -f1,2 || true)"
  PAYLOAD_VERSION="$(oc adm release info -a "${PULL_SECRET}" \
    "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" -o jsonpath='{.metadata.version}' \
    2> "${ARTIFACT_DIR}/release-info-err.txt" | cut -d. -f1,2 || true)"

  if [[ -z "${PAYLOAD_VERSION}" ]]; then
    log "WARNING: could not read the install payload version, see ${ARTIFACT_DIR}/release-info-err.txt; using the upi-installer binary (${CONTAINER_VERSION:-unknown})"
  elif [[ "${PAYLOAD_VERSION}" == "${CONTAINER_VERSION}" ]]; then
    log "upi-installer and install payload are both ${PAYLOAD_VERSION}; using the upi-installer binary"
  else
    log "upi-installer is ${CONTAINER_VERSION} but the install payload is ${PAYLOAD_VERSION}; extracting the payload's installer so the bootimage matches"
    oc adm release extract -a "${PULL_SECRET}" \
      "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
      --command=openshift-install --to=/tmp
    chmod +x /tmp/openshift-install
    INSTALLER_BINARY=/tmp/openshift-install
  fi
else
  log "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is not set; using the upi-installer binary"
fi

log "openshift-install version used for bootimage discovery:"
"${INSTALLER_BINARY}" version | grep -E "(openshift-install|build|release|architecture)"

#
# Discover RHCOS image to use for the cluster
#

if ! "${INSTALLER_BINARY}" coreos print-stream-json 2> "${ARTIFACT_DIR}/err.txt" > ${SHARED_DIR}/coreos.json; then
  log "Failed to discover RHCOS image: $(cat "${ARTIFACT_DIR}/err.txt")"
  exit 1
fi
test -s "${ARTIFACT_DIR}/err.txt" && rm "${ARTIFACT_DIR}/err.txt" || true

#
# MachineConfig for kubelet providerId
#
log "Creating manifests"
"${INSTALLER_BINARY}" create manifests --dir "${INSTALL_DIR}"

log "# << Manifest customization >> #"

#
# MachineConfig for kubelet providerId
#
function create_machineconfig_kubelet() {
    local node_role=$1
    # shellcheck disable=SC1039
    cat << EOF > "$STEP_WORKDIR/mc-kubelet-${node_role}.bu"
variant: openshift
version: 4.13.0
metadata:
  name: 00-$node_role-kubelet-providerid
  labels:
    machineconfiguration.openshift.io/role: $node_role
storage:
  files:
  - mode: 0755
    path: "/usr/local/bin/kubelet-providerid"
    contents:
      inline: |
        #!/bin/bash
        set -e -o pipefail

        # Use kubelet-env file which is already read by kubelet.service in UPI
        NODEENV=/etc/kubernetes/kubelet-env

        # Check if provider ID already set in the environment file
        if [ -e "\${NODEENV}" ] && grep -q "^KUBELET_PROVIDERID=" "\${NODEENV}"; then
            echo "KUBELET_PROVIDERID already set in \${NODEENV}"
            exit 0
        fi

        # Fetch provider ID from cloud metadata service
        PROVIDER_ID=${PROVIDER_ID_COMMAND}

        if [[ -z "\${PROVIDER_ID}" ]]; then
            echo "ERROR: Cannot obtain provider-id from the metadata service."
            exit 1
        fi

        echo "Setting KUBELET_PROVIDERID=\${PROVIDER_ID}"

        # Create kubelet-env if it doesn't exist
        if [ ! -e "\${NODEENV}" ]; then
            touch "\${NODEENV}"
        fi

        # Append provider ID to kubelet-env
        echo "KUBELET_PROVIDERID=\${PROVIDER_ID}" >> "\${NODEENV}"

        echo "Provider ID configured successfully"
systemd:
  units:
  - name: kubelet-providerid.service
    enabled: true
    contents: |
      [Unit]
      Description=Fetch kubelet provider id from Metadata
      After=NetworkManager-wait-online.service
      Before=kubelet.service
      [Service]
      ExecStart=/usr/local/bin/kubelet-providerid
      Type=oneshot
      StandardOutput=journal+console
      StandardError=journal+console
      [Install]
      WantedBy=network-online.target
EOF
}

function process_butane() {
  install_butane
  local src_file=$1; shift
  local dest_file=$1

  butane "$src_file" -o "$dest_file"
}

if [[ "${PLATFORM_EXTERNAL_CCM_ENABLED-}" == "yes" ]]; then
  echo "Creating MachineConfig for Provider ID"
  case $PROVIDER_NAME in
      "aws") PROVIDER_ID_COMMAND="aws:///\$(curl -fSs http://169.254.169.254/2022-09-24/meta-data/placement/availability-zone)/\$(curl -fSs http://169.254.169.254/2022-09-24/meta-data/instance-id)" ;;
      "oci") PROVIDER_ID_COMMAND="\$(curl -H \"Authorization: Bearer Oracle\" -sL http://169.254.169.254/opc/v2/instance/ | jq -r .id)" ;;
      *) echo "Unkonwn Provider: ${PROVIDER_NAME}"; exit 1;;
  esac

  create_machineconfig_kubelet "master"
  create_machineconfig_kubelet "worker"

  process_butane "$STEP_WORKDIR/mc-kubelet-master.bu" "${INSTALL_DIR}/openshift/99_openshift-machineconfig_00-master-kubelet-providerid.yaml"
  process_butane "$STEP_WORKDIR/mc-kubelet-worker.bu" "${INSTALL_DIR}/openshift/99_openshift-machineconfig_00-worker-kubelet-providerid.yaml"

  cp -vf -t "${ARTIFACT_DIR}/" \
    "${INSTALL_DIR}"/openshift/99_openshift-machineconfig_00-*-kubelet-providerid.yaml
fi

#
# Save infrastructure to shared dir
#

cp -vf "${INSTALL_DIR}"/manifests/cluster-infrastructure-02-config.yml "${ARTIFACT_DIR}"/cluster-infrastructure-02-config.yml

#
# Clean up MAPI manifests
#

### Remove control plane machines and CPMS
rm -vf "${INSTALL_DIR}"/openshift/99_openshift-cluster-api_master-machines-*.yaml
rm -vf "${INSTALL_DIR}"/openshift/99_openshift-machine-api_master-control-plane-machine-set.yaml

### Remove compute machinesets (optional)
rm -vf "${INSTALL_DIR}"/openshift/99_openshift-cluster-api_worker-machineset-*.yaml

log "# << Ignition config/generation >> #"

"${INSTALLER_BINARY}" --dir="${INSTALL_DIR}" create ignition-configs &
wait "$!"

log "# << Saving to shared dir >> #"

cp -vt "${SHARED_DIR}" \
  "${INSTALL_DIR}"/auth/* \
  "${INSTALL_DIR}/metadata.json" \
  "${INSTALL_DIR}"/*.ign
