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
# EXTERNAL bootstrap node can actually pull.
#
# node-image-pull.service on the bootstrap node pulls the release image by digest
# from OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE, which the installer bakes into
# bootstrap.ign. In the upgrade job that override is the ci-operator build-farm
# image (registry.build*.ci.openshift.org/ci-op-*/release@sha256:...), which the
# real AWS bootstrap node cannot reach — the pull fails with "no such object" and
# the API never comes up (confirmed run 2102722534163091456 via serial console).
#
# GA/candidate payloads are content-addressed, so the SAME manifest digest is also
# published publicly at quay.io/openshift-release-dev/ocp-release@<digest>. Rewrite
# the override to that public pullspec when the current one is a build-farm image
# and the public pullspec is actually pullable.
if [[ "$(dirname "$(dirname "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}")")" != "quay.io" ]]; then
  REL_DIGEST="$(oc adm release info -a "${PULL_SECRET}" "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" -o jsonpath='{.digest}' 2>/dev/null || true)"
  if [[ -z "${REL_DIGEST}" && "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" == *@sha256:* ]]; then
    REL_DIGEST="${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE##*@}"
  fi
  if [[ "${REL_DIGEST}" == sha256:* ]]; then
    PUBLIC_RELEASE="quay.io/openshift-release-dev/ocp-release@${REL_DIGEST}"
    log "EXPERIMENT: build-farm override ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}; probing public ${PUBLIC_RELEASE}"
    if oc adm release info -a "${PULL_SECRET}" "${PUBLIC_RELEASE}" >/dev/null 2>&1; then
      log "EXPERIMENT: public pullspec is pullable; rewriting override to ${PUBLIC_RELEASE}"
      export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="${PUBLIC_RELEASE}"
      echo -n "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" > "${SHARED_DIR}/platform-external-install-release-image"
    else
      log "EXPERIMENT: public pullspec NOT pullable; leaving override unchanged"
    fi
  else
    log "EXPERIMENT: could not resolve a sha256 digest; leaving override unchanged"
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

log "# << Injecting bootstrap serial-console diagnostics >> #"

# The bootstrap node has repeatedly hung with node-image-pull.service started and
# never finishing, and SSH resets during handshake make `openshift-install gather
# bootstrap` useless. The serial console (captured by `aws ec2 get-console-output
# --latest`, which the error handler collects) is the only channel that reliably
# reaches us.
#
# Every prior attempt failed the diagnostic unit for a DIFFERENT reason, in order:
# `After=network-online.target` (never activates this boot), then `%{http_code}`
# read as a systemd specifier in an inline ExecStart, then a base64-in-ExecStart
# rewrite that tripped Ignition's 2048-byte-per-line limit on unit contents and
# invalidated the WHOLE config (node dropped to emergency mode, run 2102701410549239808).
#
# The 2048-byte limit applies to systemd unit CONTENTS lines only. storage.files
# has no such limit, so the fix is: ship the script as a file via storage.files
# (base64 data URL — one JSON string, no line cap) and keep the unit tiny, with
# ExecStart pointing at the file. The earlier "storage.files silently dropped the
# file" was a misdiagnosis: that run's unit used `After=network-online.target` and
# never started, so the file was never read — it was not missing.
#
# TWO capture paths in one run:
#   1. opct-debug-console.service: loops every 25s dumping unit state, deps,
#      journals (node-image-pull last, so it stays inside the 64K --latest
#      window), crictl, disk, DNS, routes and registry reachability to /dev/ttyS0.
#   2. a drop-in on the native node-image-pull.service that sends its OWN
#      stdout/stderr to /dev/ttyS0, captured even if journald never flushes.
install_jq

# The diagnostic script, kept readable here and base64-encoded at step runtime.
DEBUG_SCRIPT_B64="$(base64 -w0 << 'DEBUG_SCRIPT_EOF'
#!/bin/bash
exec > /dev/ttyS0 2>&1
echo "===== OPCT-DEBUG START $(date -u --rfc-3339=seconds) ====="
echo "### ip addr ###"; ip -o addr 2>&1
echo "### ip route ###"; ip route 2>&1
echo "### resolv.conf ###"; cat /etc/resolv.conf 2>&1
echo "### node-image-pull unit ###"; systemctl cat node-image-pull.service 2>&1
echo "### node-image-pull props ###"; systemctl show node-image-pull.service -p After -p Before -p Requires -p Wants -p BindsTo -p Conditions -p ConditionResult -p AssertResult -p ExecStart -p ExecMainPID -p ActiveState -p SubState -p Result 2>&1
U="node-image-pull.service release-image.service bootkube.service crio.service crio-configure.service kubelet.service machine-config-daemon-firstboot.service"
while true; do
  echo "===== OPCT-DEBUG $(date -u --rfc-3339=seconds) ====="
  for u in $U; do echo "unit $u: $(systemctl is-active $u 2>/dev/null)/$(systemctl show -p SubState --value $u 2>/dev/null) result=$(systemctl show -p Result --value $u 2>/dev/null)"; done
  echo "### list-jobs ###"; systemctl list-jobs --no-legend 2>&1 | head -20
  echo "### procs ###"; ps -eo pid,etimes,stat,cmd 2>&1 | grep -Ei 'node-image|image-pull|crio|podman|ostree|bootkube|rpm-ostree|machine-config' | grep -v grep | head
  echo "### crictl ps ###"; crictl ps -a 2>&1 | head -15
  echo "### crictl images ###"; crictl images 2>&1 | head -15
  echo "### disk ###"; df -h / /var /run 2>&1
  echo "### registry ###"; for h in quay.io registry.ci.openshift.org; do echo "  $h: $(curl -sS -m 8 -o /dev/null -w %{http_code} https://$h/v2/ 2>&1)"; done
  echo "### dns ###"; getent hosts quay.io registry.ci.openshift.org 2>&1
  echo "### journal release-image/bootkube/crio ###"; journalctl -u release-image.service -u bootkube.service -u crio.service -u crio-configure.service --no-pager --no-hostname -o short-precise 2>&1 | tail -40
  echo "### journal boot tail ###"; journalctl -b --no-pager --no-hostname -o short-precise 2>&1 | tail -40
  echo "### journal node-image-pull (full, last) ###"; journalctl -u node-image-pull.service --no-pager --no-hostname -o short-precise 2>&1 | tail -80
  sleep 25
done
DEBUG_SCRIPT_EOF
)"

# Unit is tiny and static: it just runs the file dropped by storage.files. No $ or
# % inside, and every line is well under Ignition's 2048-byte unit-content limit.
DEBUG_UNIT="$(cat << 'DEBUG_UNIT_EOF'
[Unit]
Description=OPCT bootstrap serial console diagnostics
After=network.target
Wants=network.target

[Service]
Type=simple
Restart=always
RestartSec=10
ExecStart=/usr/local/bin/opct-debug-console.sh

[Install]
WantedBy=multi-user.target
DEBUG_UNIT_EOF
)"

# Drop-in on the native node-image-pull.service to mirror its own output to serial.
NIP_DROPIN="$(cat << 'NIP_DROPIN_EOF'
[Service]
StandardOutput=tty
StandardError=tty
TTYPath=/dev/ttyS0
NIP_DROPIN_EOF
)"

jq \
  --arg b64 "${DEBUG_SCRIPT_B64}" \
  --arg unit "${DEBUG_UNIT}" \
  --arg nipdropin "${NIP_DROPIN}" \
  '.storage.files += [{
     "path": "/usr/local/bin/opct-debug-console.sh",
     "mode": 493,
     "overwrite": true,
     "contents": {"source": ("data:text/plain;base64," + $b64)}
   }]
   | .systemd.units += [
     {"name": "opct-debug-console.service", "enabled": true, "contents": $unit},
     {"name": "node-image-pull.service", "dropins": [{"name": "10-opct-console.conf", "contents": $nipdropin}]}
   ]' \
  "${INSTALL_DIR}/bootstrap.ign" > "${INSTALL_DIR}/bootstrap.ign.new"

mv -vf "${INSTALL_DIR}/bootstrap.ign.new" "${INSTALL_DIR}/bootstrap.ign"
log "Injected opct-debug-console.service + node-image-pull console drop-in into bootstrap.ign"

log "# << Saving to shared dir >> #"

cp -vt "${SHARED_DIR}" \
  "${INSTALL_DIR}"/auth/* \
  "${INSTALL_DIR}/metadata.json" \
  "${INSTALL_DIR}"/*.ign
