#!/bin/bash

#
# Step to customize installer manifests required by Platform External for each platform.
# The step creates manifests (openshift-install create manifests) and generate the ignition
# config files (create ignition-configs), saving in a the shared storage.
#
# Always run openshift-install from OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE so bootstrap
# assets (bootkube/cvo-render flags) match the install payload. Using the step container's
# installer imagestream alone breaks upgrades when latest installer > initial CVO
# (e.g. --cluster-version-manifest-path). Same pattern as ipi-install-install extract.
#

set -o nounset
set -o errexit
set -o pipefail

if [[ -n "${PLATFORM_EXTERNAL_OVERRIDE_RELEASE-}" ]]; then
  export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="${PLATFORM_EXTERNAL_OVERRIDE_RELEASE}"
fi
echo "Using release image ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

if [[ -z "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}" ]]; then
  echo "ERROR: OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is empty"
  exit 1
fi

# Persist for preflight (exact payload baked into ignition / bootstrap)
echo -n "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" > "${SHARED_DIR}/platform-external-install-release-image"

STEP_WORKDIR=${STEP_WORKDIR:-/tmp}
INSTALL_DIR=${STEP_WORKDIR}/install-dir
mkdir -vp "${INSTALL_DIR}"

source "${SHARED_DIR}/init-fn.sh" || true

# Prefer installer binary from the install payload over the step's imagestream tag.
INSTALLER_BINARY="${STEP_WORKDIR}/openshift-install"

# Build-farm release images (registry.build*.ci.openshift.org/ci-op-*) need CI
# registry credentials. Cluster-profile pull-secret alone is not enough.
PULL_SECRET="${REGISTRY_AUTH_FILE:-${STEP_WORKDIR}/pull-secret-with-ci}"
mkdir -p "$(dirname "${PULL_SECRET}")"
cp -f "${CLUSTER_PROFILE_DIR}/pull-secret" "${PULL_SECRET}"
if [[ "$(dirname "$(dirname "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}")")" != "quay.io" ]]; then
  log "Logging into CI registry to extract installer from ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
  # Prefer build-cluster SA token over any SHARED_DIR kubeconfig.
  KUBECONFIG="" oc registry login --to "${PULL_SECRET}"
fi

# EXPERIMENT (DO NOT MERGE, OPCT-486): resolve the release image to a pullspec the
# EXTERNAL bootstrap node can actually pull by digest.
#
# node-image-pull.service on the bootstrap node pulls the release image from
# OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE, which the installer bakes into
# bootstrap.ign. In the upgrade job that override is the ci-operator build-farm
# image for `release:initial` (registry.build*.ci.openshift.org/ci-op-*/release@sha256:...).
# The bootstrap node CAN reach that registry (the passing non-upgrade job pulls its
# `release:latest` image from the same host), but the IMPORTED initial image's blobs
# are not servable by digest from the integrated registry, so the external pull
# fails with "no such object" and the API never comes up (confirmed run
# 2102722534163091456 via serial console). The pipeline `release:latest` works
# because ci-operator assembles it locally (blobs present); `release:initial` is
# imported, so only a manifest reference exists.
#
# Work around it by pointing the bootstrap at the ORIGINAL, externally-pullable
# source for the same version: nightlies live at
# registry.ci.openshift.org/ocp/release:<version>; GA/candidate at
# quay.io/openshift-release-dev/ocp-release:<version>-x86_64. Guard on the candidate
# actually being pullable before rewriting.
if [[ "$(dirname "$(dirname "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}")")" != "quay.io" ]]; then
  REL_VERSION="$(oc adm release info -a "${PULL_SECRET}" "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" -o jsonpath='{.metadata.version}' 2>/dev/null || true)"
  log "EXPERIMENT: build-farm override ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}, version=${REL_VERSION:-<unknown>}"
  PUBLIC_RELEASE=""
  if [[ "${REL_VERSION}" == *nightly* || "${REL_VERSION}" == *"-0.ci"* ]]; then
    PUBLIC_RELEASE="registry.ci.openshift.org/ocp/release:${REL_VERSION}"
  elif [[ "${REL_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    PUBLIC_RELEASE="quay.io/openshift-release-dev/ocp-release:${REL_VERSION}-x86_64"
  fi
  if [[ -n "${PUBLIC_RELEASE}" ]]; then
    log "EXPERIMENT: probing public pullspec ${PUBLIC_RELEASE}"
    if oc adm release info -a "${PULL_SECRET}" "${PUBLIC_RELEASE}" >/dev/null 2>&1; then
      log "EXPERIMENT: public pullspec is pullable; rewriting override to ${PUBLIC_RELEASE}"
      export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="${PUBLIC_RELEASE}"
      echo -n "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" > "${SHARED_DIR}/platform-external-install-release-image"
    else
      log "EXPERIMENT: public pullspec NOT pullable; leaving override unchanged"
    fi
  else
    log "EXPERIMENT: could not derive a public pullspec from version; leaving override unchanged"
  fi
fi

log "Extracting openshift-install from ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
oc adm release extract -a "${PULL_SECRET}" \
  "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
  --command=openshift-install \
  --to="${STEP_WORKDIR}"

chmod +x "${INSTALLER_BINARY}"
log "openshift-install version:"
"${INSTALLER_BINARY}" version

log "Copying to install dir"
cp -vp "${SHARED_DIR}"/install-config.yaml "${INSTALL_DIR}"/install-config.yaml

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
