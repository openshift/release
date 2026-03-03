#!/bin/bash
# gs-baremetal-orchestrate: Day-1 "no bastion" path.
# 1. Serve the agent ISO from the CI Pod (HTTP).
# 2. For each host in hosts.yaml, use Redfish/IPMI to mount that ISO and power on.
# 3. Optionally run openshift-install agent wait-for install-complete.
#
# Required in SHARED_DIR: hosts.yaml (per-host: name, host or bmc_address; for BMC: bmc_user, bmc_password).
# Required: Agent ISO at SHARED_DIR/AGENT_ISO or in INSTALL_DIR. Optional env: INSTALL_DIR, AGENT_ISO, HTTP_PORT, POD_IP.
set -euxo pipefail; shopt -s inherit_errexit

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} 2>/dev/null; wait 2>/dev/null || true; fi' TERM ERR
# Save exit code for must-gather/junit (same pattern as baremetal-lab-agent-install)
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' TERM ERR

typeset hostsYaml="${SHARED_DIR}/hosts.yaml"
[ -f "${hostsYaml}" ] || { printf '%s\n' 'SHARED_DIR/hosts.yaml is missing.' 1>&2; exit 1; }

# host-id.txt for gather step compatibility (first host's BMC identifier)
yq e -o=j -I=0 '.[0]' "${hostsYaml}" 2>/dev/null | jq -r '.host // .bmc_address // ""' > "${SHARED_DIR}/host-id.txt" || true

typeset installDir="${INSTALL_DIR:-}"
[[ -z "${installDir}" && -f "${SHARED_DIR}/install_dir_path" ]] && installDir="$(<"${SHARED_DIR}/install_dir_path")"
typeset isoPath=""
if [[ -n "${installDir}" && -d "${installDir}" ]]; then
  typeset f
  for f in "${installDir}"/agent.*.iso; do
    [[ -e "${f}" ]] && isoPath="${f}" && break
  done
fi
if [[ -z "${isoPath}" ]]; then
  typeset agentIso="${AGENT_ISO:-agent.x86_64.iso}"
  isoPath="${SHARED_DIR}/${agentIso}"
fi
[[ -f "${isoPath}" ]] || { printf '%s\n' "Agent ISO not found at ${isoPath}." 1>&2; exit 1; }

# Serve ISO: simple HTTP server in CI Pod so nodes can pull the image.
typeset httpPort="${HTTP_PORT:-8080}"
typeset isoDir isoFile
isoDir="$(dirname "${isoPath}")"
isoFile="$(basename "${isoPath}")"
(
  cd "${isoDir}"
  python3 -m http.server "${httpPort}" &
)
typeset httpPid=$!
trap 'kill ${httpPid} 2>/dev/null || true' EXIT

typeset podIp="${POD_IP:-$(hostname -I | awk '{print $1}')}"
typeset isoUrl="http://${podIp}:${httpPort}/${isoFile}"
: "Serving agent ISO at ${isoUrl}"

# Mount virtual media and power on each host via BMC (direct from pod, no AUX_HOST).
# Disable xtrace in subshell when using BMC credentials to avoid leaking in logs.
typeset bmhost name host bmcUser bmcPass wasTracing redfishUri code vmediaMounted
: "Mounting ISO and powering on hosts from hosts.yaml (host names only in logs)"
for bmhost in $(yq e -o=j -I=0 '.[]' "${hostsYaml}"); do
  (
    name="$(echo "${bmhost}" | jq -r '.name')"
    host="$(echo "${bmhost}" | jq -r '.host // .bmc_address // empty')"
    bmcUser="$(echo "${bmhost}" | jq -r '.bmc_user // "root"')"
    bmcPass="$(echo "${bmhost}" | jq -r '.bmc_password // empty')"
    [[ -n "${host}" ]] || exit 0

    [[ $- == *x* ]] && wasTracing=true || wasTracing=false
    set +x
    vmediaMounted=0
    if [[ -n "${bmcPass}" ]]; then
      typeset redfishGetCode
      redfishGetCode="$(curl -k -s -o /dev/null -w "%{http_code}" -u "${bmcUser}:${bmcPass}" "https://${host}/redfish/v1" || echo "000")"
      if [[ "${redfishGetCode}" == "200" ]]; then
        for redfishUri in \
          "https://${host}/redfish/v1/Managers/1/VirtualMedia/CD/Actions/VirtualMedia.InsertMedia" \
          "https://${host}/redfish/v1/Managers/1/VirtualMedia/2/Actions/VirtualMedia.InsertMedia"; do
          code=$(curl -k -s -o /dev/null -w "%{http_code}" -u "${bmcUser}:${bmcPass}" -X POST \
            "${redfishUri}" -H "Content-Type: application/json" \
            -d "{\"Image\": \"${isoUrl}\"}")
          if [[ "${code}" =~ ^(200|202|204)$ ]]; then
            vmediaMounted=1
            break
          fi
        done
        if [[ "${vmediaMounted}" -eq 0 ]]; then
          touch /tmp/virtual_media_mount_failure
          echo "${name}: Redfish mount FAILED (tried 2 URIs, last_code=${code})" >> /tmp/bmc-mount-summary.txt
        else
          echo "${name}: Redfish mount OK (code=${code})" >> /tmp/bmc-mount-summary.txt
        fi
      else
        echo "${name}: Redfish GET /redfish/v1 failed (code=${redfishGetCode})" >> /tmp/bmc-mount-summary.txt
      fi
      if command -v ipmitool &>/dev/null; then
        ipmitool -I lanplus -H "${host}" -U "${bmcUser}" -P "${bmcPass}" chassis bootdev cdrom || true
        ipmitool -I lanplus -H "${host}" -U "${bmcUser}" -P "${bmcPass}" chassis power cycle || true
      fi
    else
      echo "${name}: skipped (no bmc_password)" >> /tmp/bmc-mount-summary.txt
    fi
    ${wasTracing} && set -x
    true
  ) &
  sleep 2
done
wait

# Copy per-host BMC result summary to artifacts (no credentials)
cp -f /tmp/bmc-mount-summary.txt "${ARTIFACT_DIR}/" 2>/dev/null || true
if [[ -f "${ARTIFACT_DIR}/bmc-mount-summary.txt" ]]; then
  printf '%s\n' "BMC mount summary:" 1>&2
  cat "${ARTIFACT_DIR}/bmc-mount-summary.txt" 1>&2
fi

# Fail if any host failed to mount (same semantic as baremetal-lab; use virtual_media_mount_failure consistently)
if [[ -f /tmp/virtual_media_mount_failure ]]; then
  printf '%s\n' 'Failed to mount the ISO image in one or more hosts.' 1>&2
  echo "1" > "${SHARED_DIR}/install-status.txt"
  exit 1
fi

# Optional: wait for install-complete (if INSTALL_DIR is set and contains installer).
typeset oinst wExit
if [[ -n "${installDir}" && -d "${installDir}" ]]; then
  if [[ -x "${installDir}/openshift-install" || -x /tmp/openshift-install ]]; then
    oinst="${installDir}/openshift-install"
    [[ -x "${oinst}" ]] || oinst=/tmp/openshift-install
    if [[ -x "${oinst}" ]]; then
      : "Running agent wait-for install-complete..."
      set +o pipefail
      "${oinst}" --dir "${installDir}" agent wait-for install-complete --log-level=debug 2>&1 | \
        grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' || true
      wExit="${PIPESTATUS[0]}"
      set -o pipefail
      cp -f "${installDir}/auth/kubeconfig" "${SHARED_DIR}/" 2>/dev/null || true
      cp -f "${installDir}/auth/kubeadmin-password" "${SHARED_DIR}/" 2>/dev/null || true
      echo "${wExit}" > "${SHARED_DIR}/install-status.txt"
      [[ -f "${installDir}/.openshift_install.log" ]] && cp -f "${installDir}/.openshift_install.log" "${ARTIFACT_DIR}/" || true
      [[ "${wExit}" -eq 0 ]] || exit "${wExit}"
    fi
  fi
fi

# install-status.txt is set by trap on TERM/ERR or above when running wait-for; set 0 on success when we did not run wait-for
[[ ! -f "${SHARED_DIR}/install-status.txt" ]] && echo "0" > "${SHARED_DIR}/install-status.txt"

true
