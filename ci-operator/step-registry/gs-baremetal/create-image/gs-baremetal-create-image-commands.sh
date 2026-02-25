#!/bin/bash
# Day 0: runs openshift-install agent create image.
# Reads install-config.yaml and agent-config.yaml from SHARED_DIR (from gs-baremetal-conf),
# writes the agent ISO and install dir under INSTALL_DIR (default SHARED_DIR/install-dir)
# so gs-baremetal-orchestrate can serve the ISO and run wait-for install-complete.
#
# Required in SHARED_DIR: install-config.yaml, agent-config.yaml (from gs-baremetal-conf).
# Optional env: INSTALL_DIR (default: ${SHARED_DIR}/install-dir). Writes INSTALL_DIR path to
# SHARED_DIR/install_dir_path for the next step when not set via env.
set -euxo pipefail; shopt -s inherit_errexit

# Save exit code for must-gather/junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' TERM ERR

[ -f "${SHARED_DIR}/install-config.yaml" ] || { printf '%s\n' 'SHARED_DIR/install-config.yaml is missing. Run gs-baremetal-conf first.' 1>&2; exit 1; }
[ -f "${SHARED_DIR}/agent-config.yaml" ] || { printf '%s\n' 'SHARED_DIR/agent-config.yaml is missing. Run gs-baremetal-conf first.' 1>&2; exit 1; }

typeset installDir="${INSTALL_DIR:-${SHARED_DIR}/install-dir}"
mkdir -p "${installDir}"
printf '%s' "${installDir}" > "${SHARED_DIR}/install_dir_path"

typeset pullSecretPath="${CLUSTER_PROFILE_DIR}/pull-secret"
[[ -f "${pullSecretPath}" ]] || { printf '%s\n' "Pull secret not found at ${pullSecretPath}." 1>&2; exit 1; }

: "Extracting openshift-install from release image"
oc adm release extract -a "${pullSecretPath}" "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
  --command=openshift-install --to=/tmp

cp "${SHARED_DIR}/install-config.yaml" "${installDir}/"
cp "${SHARED_DIR}/agent-config.yaml" "${installDir}/"
cp /tmp/openshift-install "${installDir}/"

function Oinst() {
  set +o pipefail
  /tmp/openshift-install --dir "${installDir}" --log-level=debug "${@}" 2>&1 | \
    grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' || true
  typeset -i oinstExit=${PIPESTATUS[0]}
  set -o pipefail
  return "${oinstExit}"
}

: "Running openshift-install agent create image"
Oinst agent create image || { echo "1" > "${SHARED_DIR}/install-status.txt"; exit 1; }

typeset isoName
isoName="$(ls -1 "${installDir}"/agent.*.iso 2>/dev/null | head -1)"
[[ -n "${isoName}" && -f "${isoName}" ]] || { printf '%s\n' 'Agent ISO was not produced.' 1>&2; exit 1; }
: "Created $(basename "${isoName}") in ${installDir}"

# Copy installer logs to artifacts for debugging (no secrets; installer filters sensitive output)
[[ -f "${installDir}/.openshift_install.log" ]] && cp -f "${installDir}/.openshift_install.log" "${ARTIFACT_DIR}/" || true

true
