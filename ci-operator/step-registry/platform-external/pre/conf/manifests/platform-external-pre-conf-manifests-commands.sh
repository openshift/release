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

log "# << Injecting bootstrap serial-console diagnostics >> #"

# The bootstrap node has repeatedly hung with node-image-pull.service started and
# never finishing, and SSH resets during handshake make `openshift-install gather
# bootstrap` useless. The serial console is the only channel that still works, but
# nothing writes to it after the login prompt. Inject a unit that periodically
# dumps unit state and journal excerpts to /dev/ttyS0, so the failure is visible in
# `aws ec2 get-console-output --latest`, which the error handler already collects.
#
# Previous attempt used a storage.files entry for the script + a systemd unit
# pointing to it. Ignition wrote and enabled the unit but silently dropped the
# file, so ExecStart pointed at a missing path. This revision embeds the entire
# diagnostic script inline in the unit via ExecStart=/bin/bash -c, eliminating
# the storage.files dependency entirely.
install_jq

# Build the unit content with the diagnostic script inline.
# The script is a single long bash -c string. Newlines inside the -c '...' are
# fine for systemd — it reads the whole ExecStart value.
DEBUG_UNIT="$(cat << 'DEBUG_UNIT_EOF'
[Unit]
Description=OPCT bootstrap serial console diagnostics
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=10
ExecStart=/bin/bash -c '\
exec > /dev/ttyS0 2>&1; \
UNITS="node-image-pull.service release-image.service bootkube.service kubelet.service crio.service sshd.service"; \
while true; do \
  echo "===== OPCT-DEBUG $(date -u --rfc-3339=seconds) ====="; \
  for u in $UNITS; do \
    echo "unit $u: active=$(systemctl is-active $u 2>/dev/null) sub=$(systemctl show -p SubState --value $u 2>/dev/null)"; \
  done; \
  echo "--- systemd jobs still running:"; \
  systemctl list-jobs --no-legend 2>/dev/null | head -10; \
  echo "--- registry reachability:"; \
  for host in quay.io registry.ci.openshift.org; do \
    echo "  $host: $(curl -sS -m 10 -o /dev/null -w %{http_code} https://$host/v2/ 2>&1)"; \
  done; \
  echo "--- journal (node-image-pull, release-image, bootkube):"; \
  journalctl -n 25 --no-pager --no-hostname -o short-precise \
    -u node-image-pull.service -u release-image.service -u bootkube.service 2>/dev/null; \
  echo "--- journal (sshd):"; \
  journalctl -n 10 --no-pager --no-hostname -o short-precise -u sshd.service 2>/dev/null; \
  sleep 30; \
done'

[Install]
WantedBy=multi-user.target
DEBUG_UNIT_EOF
)"

jq \
  --arg unit "${DEBUG_UNIT}" \
  '.systemd.units += [{
     "name": "opct-debug-console.service",
     "enabled": true,
     "contents": $unit
   }]' \
  "${INSTALL_DIR}/bootstrap.ign" > "${INSTALL_DIR}/bootstrap.ign.new"

mv -vf "${INSTALL_DIR}/bootstrap.ign.new" "${INSTALL_DIR}/bootstrap.ign"
log "Injected opct-debug-console.service into bootstrap.ign"

log "# << Saving to shared dir >> #"

cp -vt "${SHARED_DIR}" \
  "${INSTALL_DIR}"/auth/* \
  "${INSTALL_DIR}/metadata.json" \
  "${INSTALL_DIR}"/*.ign
