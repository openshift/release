#!/bin/bash
#
# Verify post-migration VM state produced by p2p-mtv-execute-live-migration.
#
# Checks (all hard-fail; recorded as JUnit cases):
# destination VMIs Running; destination VM runStrategy==Always (OCPBUGS-101771);
# source VMIM not Failed (OCPBUGS-99403); SSH port 22 from a peer virt-launcher;
# SSH login (virtctl ssh); cloud-init data integrity marker; guest disk I/O;
# guest-level ping to a peer VM. In-guest checks run over virtctl ssh.
#
# Results written to ${ARTIFACT_DIR}/junit_cclm_migration_verify${suffix}.xml.
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
  typeset -a _fURL=()
  type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
  "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

if [[ -n "${SHARED_DIR}" && -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
  # Disable xtrace: proxy-conf.sh may embed credentials in HTTP_PROXY values.
  typeset _wasTracing=''
  [[ $- == *x* ]] && _wasTracing=true || _wasTracing=false
  set +x
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
  [[ "${_wasTracing}" == "true" ]] && set -x
fi

[[ -n "${KUBECONFIG}" ]]
[[ -r "${KUBECONFIG}" ]]

typeset -i vmCount="${MTV_TEST_VM_COUNT}"
typeset -i sourceSpokeIndex="${MTV_SOURCE_SPOKE_INDEX}"
typeset -i destSpokeIndex="${MTV_DEST_SPOKE_INDEX}"
typeset sourceKubeconfig="${MTV_SOURCE_SPOKE_KUBECONFIG}"
typeset destKubeconfig="${MTV_DEST_SPOKE_KUBECONFIG}"
typeset targetNs="${MTV_TEST_VM_TARGET_NAMESPACE}"
typeset vmSshVerify="${MTV_VM_SSH_VERIFY}"
typeset vmGuestExec="${MTV_VM_GUEST_EXEC}"
typeset -i sshWaitSeconds="${MTV_VM_SSH_WAIT_SECONDS}"
typeset sshUser="${MTV_VM_SSH_USER}"
typeset virtctlBin="" sshKeyFile="" sshReady=false
typeset migrationSuffix="${MTV_MIGRATION_SUFFIX:-}"
typeset diagDir=""
typeset pvcCheck="${MTV_PVC_CHECK:-true}"
typeset rootdiskSize="${MTV_VM_ROOTDISK_SIZE:-}"

(( vmCount >= 1 )) \
  || { printf 'ERROR: MTV_TEST_VM_COUNT must be a positive integer (got: %s)\n' "${MTV_TEST_VM_COUNT}" >&2; false; }

# Temp file accumulating tab-separated JUnit records (PASS/FAIL/WARN\tname\telapsed\t[msg]).
typeset -r junitFile="${TMPDIR:-/tmp}/cclm-verify${migrationSuffix}-junit-$$.tsv"

# VmName — return the VM name for a 1-based index.
# When vmCount=1 returns MTV_TEST_VM_NAME unchanged (backward compat).
function VmName () {
  typeset -i idx="${1:?}"; (($#)) && shift
  if (( vmCount == 1 )); then
    printf '%s' "${MTV_TEST_VM_NAME}"
  else
    printf '%s-%d' "${P2P_HS_SPOKE_VM_PREFIX:-test-vm}" "${idx}"
  fi
  true
}

# OcWithRedactedStderr — run a command with stdout unchanged and stderr passed through
# RedactOutput. Always uses /tmp (never TMPDIR/ARTIFACT_DIR) so unredacted oc errors
# cannot be collected as CI artifacts. xtrace is disabled so kubeconfig paths and
# command lines are not logged. A temp file is used instead of 2> >(RedactOutput >&2)
# because process substitution races under command substitution ($(...)).
function OcWithRedactedStderr () {
  typeset _wasTracing=''
  [[ $- == *x* ]] && _wasTracing=true || _wasTracing=false
  set +x

  typeset _errFile
  _errFile="$(mktemp /tmp/oc-stderr.XXXXXX)"
  typeset -i _rc=0
  "$@" 2>"${_errFile}" || _rc=$?
  if [[ -s "${_errFile}" ]]; then
    RedactOutput < "${_errFile}" >&2 || true
  fi
  rm -f "${_errFile}"

  if [[ "${_wasTracing}" == "true" ]]; then
    set -x
  fi
  return "${_rc}"
}

# HubOc — run oc against the ACM hub.
function HubOc () {
  OcWithRedactedStderr oc --kubeconfig="${KUBECONFIG}" "$@"
}

# SourceOc — run oc against the source spoke.
function SourceOc () {
  OcWithRedactedStderr oc --kubeconfig="${sourceKubeconfig}" "$@"
}

# DestOc — run oc against the destination spoke. stderr is redacted so API-server
# URLs and IPs from connection errors cannot reach public CI logs.
function DestOc () {
  OcWithRedactedStderr oc --kubeconfig="${destKubeconfig}" "$@"
}

# ResolveSpokeKubeconfigs — source and destination spoke admin kubeconfigs.
# Index 0 sentinel: hub cluster — resolves to KUBECONFIG (the ACM hub/host provider).
# Positive index N: resolves to SHARED_DIR/managed-cluster-kubeconfig-N (spoke cluster).
function ResolveSpokeKubeconfigs () {
  [[ -n "${SHARED_DIR}" ]]

  if [[ -z "${sourceKubeconfig}" ]]; then
    if (( sourceSpokeIndex == 0 )); then
      sourceKubeconfig="${KUBECONFIG}"
    elif [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig-${sourceSpokeIndex}" ]]; then
      sourceKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig-${sourceSpokeIndex}"
    elif (( sourceSpokeIndex == 1 )) && [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
      sourceKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig"
    else
      printf 'ERROR: Source spoke kubeconfig not found for index %d\n' "${sourceSpokeIndex}" >&2
      false
    fi
  fi
  [[ -r "${sourceKubeconfig}" ]]

  if [[ -z "${destKubeconfig}" ]]; then
    if (( destSpokeIndex == 0 )); then
      destKubeconfig="${KUBECONFIG}"
    elif [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig-${destSpokeIndex}" ]]; then
      destKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig-${destSpokeIndex}"
    elif (( destSpokeIndex == 1 )) && [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
      destKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig"
    else
      printf 'ERROR: Dest spoke kubeconfig not found for index %d\n' "${destSpokeIndex}" >&2
      false
    fi
  fi
  [[ -r "${destKubeconfig}" ]]
  true
}

# DumpDiagnostics — collect VM and VMIM state to ARTIFACT_DIR for debugging failures.
# Artifacts are publicly readable: no -o wide (pod IPs, node names), VMIMs are projected
# to phase/conditions (migrationState carries node names and addresses), and every
# output is passed through RedactOutput.
function DumpDiagnostics () {
  [[ -n "${ARTIFACT_DIR}" ]] || return 0
  diagDir="${ARTIFACT_DIR}/mtv-migration-verify${migrationSuffix}-diagnostics"
  mkdir -p "${diagDir}"
  typeset vmimFilter='[.items[] | {name: .metadata.name, vmiName: .spec.vmiName,
    phase: .status.phase, conditions: .status.conditions,
    failed: .status.migrationState.failed,
    failureReason: .status.migrationState.failureReason}]'

  HubOc get plan,migration -n "${MTV_NAMESPACE}" 2>&1 \
    | RedactOutput > "${diagDir}/hub-mtv-resources.txt" || true
  HubOc get events -n "${MTV_NAMESPACE}" --sort-by='.lastTimestamp' 2>&1 \
    | RedactOutput > "${diagDir}/hub-mtv-events.txt" || true

  typeset -i k
  for (( k = 1; k <= vmCount; k++ )); do
    typeset vn
    vn="$(VmName "${k}")"
    # custom-columns omits VMI IP and node name (default printer includes both).
    SourceOc get "virtualmachine/${vn}" "virtualmachineinstance/${vn}" \
      -n "${MTV_TEST_VM_NAMESPACE}" \
      -o custom-columns=KIND:.kind,NAME:.metadata.name,PHASE:.status.phase \
      2>&1 \
      | RedactOutput > "${diagDir}/source-vm-${vn}.txt" || true
    DestOc get "virtualmachine/${vn}" "virtualmachineinstance/${vn}" \
      -n "${targetNs}" \
      -o custom-columns=KIND:.kind,NAME:.metadata.name,PHASE:.status.phase \
      2>&1 \
      | RedactOutput > "${diagDir}/dest-vm-${vn}.txt" || true
  done
  { SourceOc get vmim -n "${MTV_TEST_VM_NAMESPACE}" -o json | jq "${vmimFilter}"; } 2>&1 \
    | RedactOutput > "${diagDir}/source-vmim.json" || true
  { DestOc get vmim -n "${targetNs}" -o json | jq "${vmimFilter}"; } 2>&1 \
    | RedactOutput > "${diagDir}/dest-vmim.json" || true
  DestOc get pods -n "${targetNs}" 2>&1 \
    | RedactOutput > "${diagDir}/dest-pods.txt" || true
  SourceOc get pods -n "${MTV_CNV_NAMESPACE}" 2>&1 \
    | RedactOutput > "${diagDir}/source-cnv-pods.txt" || true
  DestOc get pods -n "${MTV_CNV_NAMESPACE}" 2>&1 \
    | RedactOutput > "${diagDir}/dest-cnv-pods.txt" || true
  DestOc get datavolume,pvc -n "${targetNs}" 2>&1 \
    | RedactOutput > "${diagDir}/dest-storage.txt" || true
  true
}

# OnError — dump diagnostics before propagating failure.
function OnError () {
  typeset -i ec=$?
  DumpDiagnostics
  exit "${ec}"
}

# VmimPhase — read VirtualMachineInstanceMigration phase for a specific VM on a spoke.
# Filters by the vmim's vmi name label to handle multi-VM migration plans correctly.
function VmimPhase () {
  typeset kc="${1:?}"; (($#)) && shift
  typeset ns="${1:?}"; (($#)) && shift
  typeset vmName="${1:?}"; (($#)) && shift

  OcWithRedactedStderr oc --kubeconfig="${kc}" get vmim -n "${ns}" -o json \
    | OcWithRedactedStderr jq -r --arg vm "${vmName}" \
      'first(.items[] | select(.spec.vmiName == $vm) | .status.phase) // ""'
}

# VerifyMigration — all destination VMIs must be Running after migration.
function VerifyMigration () {
  typeset -i i
  typeset vmName destPhase

  for (( i = 1; i <= vmCount; i++ )); do
    vmName="$(VmName "${i}")"
    destPhase="$(DestOc get "virtualmachineinstance/${vmName}" -n "${targetNs}" \
      -o jsonpath='{.status.phase}' || true)"
    [[ "${destPhase}" == "Running" ]] || {
      printf 'ERROR: VMI %s not Running on destination (phase=%s)\n' "${vmName}" "${destPhase}" >&2
      return 1
    }
  done
  true
}

# VerifyDestVmsRunStrategy — destination VMs must have runStrategy=Always after migration.
# Guards against OCPBUGS-101771 where Forklift leaves runStrategy=Halted after migration,
# silently breaking VM auto-restart (the migrated VM will not recover from a pod crash
# without a manual start). This is a Forklift bug that interop must detect, not patch.
function VerifyDestVmsRunStrategy () {
  typeset -i i
  typeset vmName strategy

  for (( i = 1; i <= vmCount; i++ )); do
    vmName="$(VmName "${i}")"
    strategy="$(DestOc get "virtualmachine/${vmName}" -n "${targetNs}" \
      -o jsonpath='{.spec.runStrategy}' || true)"
    [[ "${strategy}" == "Always" ]] || {
      printf "ERROR: VM %s runStrategy='%s', expected 'Always' (OCPBUGS-101771)\n" "${vmName}" "${strategy}" >&2
      return 1
    }
  done
  true
}

# VerifySourceVmimNotFailed — source VMIMs must not be in Failed phase after migration.
# Guards against OCPBUGS-99403 where a mid-migration QEMU socket disruption causes the
# guest to crash on source while Forklift reports Succeeded based on target-side status only.
# An absent VMIM (phase="") means it was cleaned up after success — that is expected.
function VerifySourceVmimNotFailed () {
  typeset -i i
  typeset vmName srcVmimPhase

  for (( i = 1; i <= vmCount; i++ )); do
    vmName="$(VmName "${i}")"
    srcVmimPhase="$(VmimPhase "${sourceKubeconfig}" "${MTV_TEST_VM_NAMESPACE}" "${vmName}")" || {
      printf 'ERROR: failed to query source VMIM for %s\n' "${vmName}" >&2
      return 1
    }
    [[ "${srcVmimPhase}" != "Failed" ]] || {
      printf 'ERROR: Source VMIM for %s is Failed — false-positive migration (OCPBUGS-99403)\n' "${vmName}" >&2
      return 1
    }
  done
  true
}

# VerifyAllVmsSsh — probe SSH port 22 on each migrated VM via a peer virt-launcher.
# Uses cross-VM probing: VM[i] is probed from VM[(i+1)%N]'s virt-launcher, so
# the anchor pod differs from the target VM (avoids hairpin NAT in masquerade mode).
# Skipped (SKIP JUnit record, rc=77) for vmCount=1 (no peer), non-live plans, or
# when MTV_VM_SSH_VERIFY=false. Hard fail: missing IP or unreachable port fails the step.
function VerifyAllVmsSsh () {
  [[ "${vmSshVerify}" == "true" ]] || return 77
  [[ "${MTV_PLAN_TYPE}" == "live" ]] || return 77
  (( vmCount > 1 )) || return 77

  typeset -a vmNamesArr=()
  typeset -a launcherPodsArr=()
  CollectDestLaunchers vmNamesArr launcherPodsArr

  typeset -i i failed=0
  for (( i = 0; i < vmCount; i++ )); do
    typeset vmName
    vmName="${vmNamesArr[${i}]}"

    typeset -i anchorIdx=$(( (i + 1) % vmCount ))

    if [[ -z "${launcherPodsArr[${anchorIdx}]}" ]]; then
      printf 'ERROR: no probe anchor for SSH check on %s\n' "${vmName}" >&2
      (( ++failed ))
      continue
    fi

    typeset probeRc=0
    ( set +x
      vmIp="$(DestOc get "virtualmachineinstance/${vmName}" -n "${targetNs}" \
        -o jsonpath='{.status.interfaces[0].ipAddress}' || true)"
      anchorPod="${launcherPodsArr[${anchorIdx}]}"
      [[ -n "${vmIp}" ]] || exit 2
      DestOc exec -n "${targetNs}" "${anchorPod}" -c compute -- \
        timeout 15 bash -c "echo > /dev/tcp/${vmIp}/22"
    ) || probeRc=$?

    case "${probeRc}" in
      0) : "SSH port 22 reachable on ${vmName}" ;;
      2) printf 'ERROR: no IP on VMI %s for SSH probe\n' "${vmName}" >&2
         (( ++failed )) ;;
      *) printf 'ERROR: SSH port 22 not reachable on %s (rc=%d)\n' "${vmName}" "${probeRc}" >&2
         (( ++failed )) ;;
    esac
  done

  (( failed == 0 ))
}

# RedactOutput — mask URLs, IPv4 addresses, and AWS node hostnames (ip-A-B-C-D.*) in
# ssh/virtctl error text and diagnostics artifacts.
function RedactOutput () {
  sed -E -e 's#https?://[^[:space:]]+#<REDACTED-URL>#g' \
    -e 's#ip-[0-9]+-[0-9]+-[0-9]+-[0-9]+[.a-z0-9-]*#<REDACTED-NODE>#g' \
    -e 's#[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+#<REDACTED-IP>#g'
}

# EnsurePasswdEntry — the OpenSSH client refuses to run when the pod's random UID
# has no passwd entry; the cli-with-ssh image makes /etc/passwd group-writable.
function EnsurePasswdEntry () {
  whoami &>/dev/null && return 0
  [[ -w /etc/passwd ]] || {
    printf 'ERROR: no passwd entry for uid %s and /etc/passwd is not writable\n' "$(id -u)" >&2
    return 1
  }
  printf '%s:x:%s:0:%s user:%s:/sbin/nologin\n' \
    "${USER_NAME:-default}" "$(id -u)" "${USER_NAME:-default}" "${HOME}" >> /etc/passwd
}

# InstallVirtctl — download virtctl matching the destination CNV version from its
# hyperconverged-cluster-cli-download route. Runs under set +x (route host is a cluster URL).
function InstallVirtctl () {
  typeset binDir="${TMPDIR:-/tmp}/cclm-verify-bin"
  mkdir -p "${binDir}"
  ( set +x
    typeset host
    host="$(DestOc get route hyperconverged-cluster-cli-download -n "${MTV_CNV_NAMESPACE}" \
      -o jsonpath='{.spec.host}')" || exit 1
    [[ -n "${host}" ]] || exit 1
    curl -kfsSL "https://${host}/amd64/linux/virtctl.tar.gz" | tar -xz -C "${binDir}"
  ) || return 1
  virtctlBin="${binDir}/virtctl"
  "${virtctlBin}" version --client 1>/dev/null
}

# PrepareSshAccess — key from SHARED_DIR (written by p2p-create-cclm-test-vms) + virtctl.
function PrepareSshAccess () {
  typeset srcKey="${SHARED_DIR}/${MTV_VM_SSH_KEY_NAME}"
  [[ -s "${srcKey}" ]] || {
    printf 'ERROR: VM SSH key %s not found in SHARED_DIR\n' "${MTV_VM_SSH_KEY_NAME}" >&2
    return 1
  }
  sshKeyFile="/tmp/cclm-verify-ssh-key-$$"
  install -m 0600 "${srcKey}" "${sshKeyFile}" || return 1
  [[ -w "${HOME:-/}" ]] || export HOME="${TMPDIR:-/tmp}"
  EnsurePasswdEntry || return 1
  command -v ssh 1>/dev/null || { printf 'ERROR: ssh client not found in step image\n' >&2; return 1; }
  InstallVirtctl || { printf 'ERROR: failed to install virtctl from the destination cluster\n' >&2; return 1; }
}

# VmSsh — run a command inside a destination VM via virtctl ssh (API server port-forward,
# so it works with masquerade networking). stdin is closed so loops are not consumed.
# KUBECONFIG must be set in the environment: the ssh ProxyCommand virtctl generates
# (virtctl port-forward --stdio) does not inherit a --kubeconfig flag.
function VmSsh () {
  typeset vmName="${1:?}"; (($#)) && shift
  typeset cmd="${1:?}"; (($#)) && shift
  KUBECONFIG="${destKubeconfig}" "${virtctlBin}" ssh "${sshUser}@vmi/${vmName}" \
    --namespace="${targetNs}" --identity-file="${sshKeyFile}" --known-hosts=/dev/null \
    --local-ssh-opts='-o StrictHostKeyChecking=no' \
    --local-ssh-opts='-o UserKnownHostsFile=/dev/null' \
    --local-ssh-opts='-o BatchMode=yes' \
    --local-ssh-opts='-o ConnectTimeout=15' \
    --local-ssh-opts='-o LogLevel=ERROR' \
    --command="${cmd}" 0</dev/null
}

# VmSshChecked — VmSsh, logging the (redacted) tail of stderr on failure.
function VmSshChecked () {
  typeset vmName="${1:?}"
  typeset errFile="/tmp/cclm-verify-ssh-err-$$"
  typeset -i rc=0
  VmSsh "$@" 2>"${errFile}" || rc=$?
  if (( rc != 0 )); then
    printf 'ERROR: ssh command on %s failed (rc=%d): %s\n' "${vmName}" "${rc}" \
      "$(RedactOutput < "${errFile}" | tail -n 3 | tr '\n' ' ')" >&2
  fi
  return "${rc}"
}

# WaitDestSshReady — gate in-guest checks until every destination VM accepts an SSH login.
# MTV_VM_SSH_WAIT_SECONDS is one budget shared by all VMs (cloud-init may still be finishing);
# it must stay below the step timeout so JUnit and diagnostics are still written on failure.
# Skipped (return 77) when both MTV_VM_DATA_INTEGRITY and MTV_VM_GUEST_EXEC are false.
function WaitDestSshReady () {
  if [[ "${MTV_VM_DATA_INTEGRITY}" != 'true' && "${vmGuestExec}" != 'true' ]]; then
    return 77
  fi
  PrepareSshAccess || return 1

  typeset errFile="/tmp/cclm-verify-ssh-err-$$"
  typeset -i i deadline=$(( SECONDS + sshWaitSeconds ))
  for (( i = 1; i <= vmCount; i++ )); do
    typeset vmName; vmName="$(VmName "${i}")"
    typeset -i ready=0
    while :; do
      # set +x: avoid logging the full virtctl ssh command line on every 10s retry.
      if ( set +x; VmSsh "${vmName}" true 1>/dev/null 2>"${errFile}" ); then
        ready=1
        break
      fi
      (( SECONDS < deadline )) || break
      sleep 10
    done
    if (( ready == 0 )); then
      printf 'ERROR: SSH login to %s still failing after the %ds wait budget; last error: %s\n' \
        "${vmName}" "${sshWaitSeconds}" \
        "$(RedactOutput < "${errFile}" | tail -n 3 | tr '\n' ' ')" >&2
      return 1
    fi
  done
  sshReady=true
}

# VerifyVmDataIntegrity — verify that cloud-init marker files survive migration intact.
# p2p-create-cclm-test-vms injects a cloud-init runcmd step that writes
# /home/cloud-user/migration-marker.txt with content equal to the VM name.
# This function reads back that file on the destination over SSH and compares it to
# the expected VM name. Any VM whose marker is missing or different fails the step.
function VerifyVmDataIntegrity () {
  [[ "${MTV_VM_DATA_INTEGRITY}" == "true" ]] || return 77
  [[ "${sshReady}" == "true" ]] || {
    printf 'ERROR: destination SSH not ready; data integrity not checked\n' >&2
    return 1
  }

  # Disable xtrace: marker content must not appear in CI logs.
  typeset _wasTracing=''
  [[ $- == *x* ]] && _wasTracing=true || _wasTracing=false
  set +x

  typeset -i i failed=0
  for (( i = 1; i <= vmCount; i++ )); do
    typeset vmName actualMarker=""
    vmName="$(VmName "${i}")"

    if ! actualMarker="$(VmSshChecked "${vmName}" 'cat /home/cloud-user/migration-marker.txt')"; then
      printf 'ERROR: Integrity marker missing or unreadable on %s\n' "${vmName}" >&2
      (( ++failed ))
      continue
    fi

    if [[ "${actualMarker%$'\r'}" == "${vmName}" ]]; then
      : "Data integrity verified for ${vmName}"
    else
      # Log only a mismatch indicator — never log raw marker content.
      printf 'ERROR: Data integrity FAIL for %s (marker mismatch)\n' "${vmName}" >&2
      (( ++failed ))
    fi
  done

  [[ "${_wasTracing}" == "true" ]] && set -x
  (( failed == 0 ))
}

# CollectDestLaunchers — fill nameref arrays of VM names and Running virt-launcher pods.
# Runs under set +x: pod names are internal cluster identifiers that must not appear
# in CI logs via xtrace variable-assignment tracing.
#
# Pod lookup uses two strategies to handle label differences after CCLM migration:
# 1. kubevirt.io/domain= label (standard KubeVirt label; may be absent post-CCLM).
# 2. Pod name prefix virt-launcher-<vmname>- (fallback; matches proven GetSourceVirtLauncherPod
#    pattern used in p2p-mtv-execute-hub-spoke-migration-commands.sh).
# All pods are fetched once with kubevirt.io=virt-launcher to scope the snapshot.
function CollectDestLaunchers () {
  typeset -n _names="${1:?}"; (($#)) && shift
  typeset -n _pods="${1:?}"; (($#)) && shift
  typeset -i i
  _names=()
  _pods=()

  # Disable xtrace: pod name assignments are printed by xtrace and must be suppressed.
  typeset _wasTracing=''
  [[ $- == *x* ]] && _wasTracing=true || _wasTracing=false
  set +x

  # Snapshot all virt-launcher pods once — avoids N oc calls in the loop.
  typeset podsJson
  podsJson="$(DestOc get pods -n "${targetNs}" -l kubevirt.io=virt-launcher -o json || true)"

  for (( i = 1; i <= vmCount; i++ )); do
    typeset vmn pod
    vmn="$(VmName "${i}")"
    _names+=("${vmn}")

    # Strategy 1: kubevirt.io/domain label equals VM name.
    pod="$(printf '%s' "${podsJson}" \
      | OcWithRedactedStderr jq -r --arg d "${vmn}" \
        'first(.items[]
         | select(.metadata.labels["kubevirt.io/domain"]==$d)
         | select(.status.phase=="Running")
         | .metadata.name) // ""' \
      || true)"

    # Strategy 2: pod name prefix fallback (post-CCLM pods may lack the domain label).
    if [[ -z "${pod}" ]]; then
      pod="$(printf '%s' "${podsJson}" \
        | OcWithRedactedStderr jq -r --arg n "${vmn}" \
          'first(.items[]
           | select(.metadata.name | startswith("virt-launcher-" + $n + "-"))
           | select(.status.phase=="Running")
           | .metadata.name) // ""' \
        || true)"
    fi

    _pods+=("${pod}")
  done

  [[ "${_wasTracing}" == "true" ]] && set -x
  true
}

# VerifyGuestDiskIo — write, fsync, checksum, and remove a scratch file inside each guest.
# Proves the migrated root disk is writable and readable after CCLM (not just VMI Running).
# Skipped (SKIP JUnit record, rc=77) when MTV_VM_GUEST_EXEC=false (e.g. cirros VMs).
function VerifyGuestDiskIo () {
  [[ "${vmGuestExec}" == "true" ]] || return 77
  [[ "${sshReady}" == "true" ]] || {
    printf 'ERROR: destination SSH not ready; guest disk I/O not checked\n' >&2
    return 1
  }

  typeset ioCmd='dd if=/dev/zero of=/tmp/cclm-io.bin bs=1M count=4 conv=fsync status=none && sha256sum /tmp/cclm-io.bin && rm -f /tmp/cclm-io.bin'
  typeset -i i failed=0
  for (( i = 1; i <= vmCount; i++ )); do
    typeset vmName; vmName="$(VmName "${i}")"
    if VmSshChecked "${vmName}" "${ioCmd}" 1>/dev/null; then
      : "Guest disk I/O succeeded on ${vmName}"
    else
      printf 'ERROR: guest disk I/O command failed on %s\n' "${vmName}" >&2
      (( ++failed ))
    fi
  done
  (( failed == 0 ))
}

# VerifyGuestNetwork — ping a peer VM IP from inside each guest (guest-level reachability).
# Distinct from the SSH TCP probe which runs in the virt-launcher pod, not the guest.
# Skipped (SKIP JUnit record, rc=77) for vmCount=1 (no peer) or when MTV_VM_GUEST_EXEC=false.
function VerifyGuestNetwork () {
  [[ "${vmGuestExec}" == "true" ]] || return 77
  (( vmCount > 1 )) || return 77
  [[ "${sshReady}" == "true" ]] || {
    printf 'ERROR: destination SSH not ready; guest network not checked\n' >&2
    return 1
  }

  typeset -i i failed=0
  for (( i = 1; i <= vmCount; i++ )); do
    typeset vmName peerName
    vmName="$(VmName "${i}")"
    peerName="$(VmName $(( i % vmCount + 1 )))"

    typeset probeRc=0
    # set +x: peer IP is an internal cluster address.
    ( set +x
      typeset peerIp
      peerIp="$(DestOc get "virtualmachineinstance/${peerName}" -n "${targetNs}" \
        -o jsonpath='{.status.interfaces[0].ipAddress}' || true)"
      [[ -n "${peerIp}" ]] || exit 2
      VmSshChecked "${vmName}" "ping -c 2 -W 5 ${peerIp}" 1>/dev/null
    ) || probeRc=$?

    case "${probeRc}" in
      0) : "Guest ping to peer succeeded on ${vmName}" ;;
      2) printf 'ERROR: no IP on peer VMI for guest network check on %s\n' "${vmName}" >&2
         (( ++failed )) ;;
      *) printf 'ERROR: guest ping to peer failed on %s (rc=%d)\n' "${vmName}" "${probeRc}" >&2
         (( ++failed )) ;;
    esac
  done
  (( failed == 0 ))
}

# VerifyPvcAttachment — verify the destination VM spec references the expected rootdisk PVC as a
# volume. Guards against Forklift silently detaching the PVC from the VM spec during migration
# while the VMI still appears Running (the VM would fail to restart after a pod crash).
# Skipped (rc=77) when MTV_PVC_CHECK=false.
function VerifyPvcAttachment () {
  [[ "${pvcCheck}" == "true" ]] || return 77

  # Disable xtrace: VM JSON may contain internal node hostnames and IP addresses
  # that must not appear in CI logs via xtrace variable-expansion tracing.
  typeset _wasTracing=''
  [[ $- == *x* ]] && _wasTracing=true || _wasTracing=false
  set +x

  typeset -i _rc=0
  {
    typeset -i i failed=0
    for (( i = 1; i <= vmCount; i++ )); do
      typeset vmName; vmName="$(VmName "${i}")"
      typeset expectedPvc="${vmName}-rootdisk"
      typeset -i attached=0

      # Fetch VM separately so an API/missing-VM error is reported with its real cause,
      # not misreported as "PVC not attached".
      typeset vmJson
      vmJson="$(DestOc get "virtualmachine/${vmName}" -n "${targetNs}" -o json)" || {
        printf 'ERROR: Cannot read VM %s on destination\n' "${vmName}" >&2
        (( ++failed ))
        continue
      }

      # jq -e exits 1 when any() returns false. stdout discarded (boolean only).
      # jq stderr is redacted so a parse error cannot dump VM JSON (IPs/hostnames)
      # into CI logs. []? tolerates a VM spec with no volumes field.
      if printf '%s' "${vmJson}" | OcWithRedactedStderr jq -e --arg pvc "${expectedPvc}" \
          'any(.spec.template.spec.volumes[]?;
            .dataVolume.name==$pvc or .persistentVolumeClaim.claimName==$pvc)' \
        1>/dev/null; then
        attached=1
      fi

      if (( attached == 0 )); then
        printf 'ERROR: VM %s on destination does not have PVC %s attached as a volume\n' \
          "${vmName}" "${expectedPvc}" >&2
        (( ++failed ))
      fi
    done
    (( failed == 0 ))
  } || _rc=$?

  if [[ "${_wasTracing}" == "true" ]]; then
    set -x
  fi
  return "${_rc}"
}

# VerifyPvcIntegrity — verify the rootdisk PVC on the destination is Bound and, when
# MTV_VM_ROOTDISK_SIZE is set, that the requested storage size is preserved. The observed
# capacity is logged for human review in all cases.
# Skipped (rc=77) when MTV_PVC_CHECK=false.
function VerifyPvcIntegrity () {
  [[ "${pvcCheck}" == "true" ]] || return 77

  # Disable xtrace: PVC JSON may contain storage-provider annotations and internal
  # metadata fields that must not appear in CI logs via xtrace variable-expansion tracing.
  typeset _wasTracing=''
  [[ $- == *x* ]] && _wasTracing=true || _wasTracing=false
  set +x

  typeset -i _rc=0
  {
    typeset -i i failed=0
    for (( i = 1; i <= vmCount; i++ )); do
      typeset vmName; vmName="$(VmName "${i}")"
      typeset pvcName="${vmName}-rootdisk"

      typeset pvcJson
      # DestOc redacts oc stderr (URLs/IPs). Do not use 2>/dev/null — NotFound and
      # auth/network errors must still appear in CI logs after redaction.
      pvcJson="$(DestOc get "pvc/${pvcName}" -n "${targetNs}" -o json)" || {
        printf 'ERROR: PVC %s not found or unreadable on destination for VM %s\n' "${pvcName}" "${vmName}" >&2
        (( ++failed ))
        continue
      }

      # Phase check — PVC must be Bound.
      typeset phase
      phase="$(printf '%s' "${pvcJson}" | OcWithRedactedStderr jq -r '.status.phase // ""')"
      if [[ "${phase}" != "Bound" ]]; then
        printf 'ERROR: PVC %s on destination has phase=%s, expected Bound\n' "${pvcName}" "${phase}" >&2
        (( ++failed ))
      fi

      # Log observed capacity for human review; not a failure if it differs (provisioners may round up).
      # Use printf >&2 (not : "...") — the null-command is invisible inside set +x and produces no output.
      typeset capacityStr
      capacityStr="$(printf '%s' "${pvcJson}" | OcWithRedactedStderr jq -r '.status.capacity.storage // ""')"
      printf 'INFO: PVC %s status.capacity.storage=%s\n' "${pvcName}" "${capacityStr:-<empty>}" >&2

      # Size check — compare spec.resources.requests.storage when MTV_VM_ROOTDISK_SIZE is set.
      if [[ -n "${rootdiskSize}" ]]; then
        typeset requestedSize
        requestedSize="$(printf '%s' "${pvcJson}" | OcWithRedactedStderr jq -r '.spec.resources.requests.storage // ""')"
        if [[ "${requestedSize}" != "${rootdiskSize}" ]]; then
          printf 'ERROR: PVC %s requested storage=%s, expected %s (MTV_VM_ROOTDISK_SIZE)\n' \
            "${pvcName}" "${requestedSize}" "${rootdiskSize}" >&2
          (( ++failed ))
        fi
      fi
    done
    (( failed == 0 ))
  } || _rc=$?

  if [[ "${_wasTracing}" == "true" ]]; then
    set -x
  fi
  return "${_rc}"
}

# JStep — run a function, append PASS/FAIL/SKIP record to junitFile, propagate exit code.
# rc=0: PASS — check executed and succeeded.
# rc=77: SKIP — preconditions not met; check intentionally not executed.
# Returns 0 so the ERR trap is not triggered and subsequent steps run.
# other: FAIL — check executed and failed; original rc propagated (triggers ERR trap).
function JStep () {
  typeset name="${1:?}"; (($#)) && shift
  typeset -i t0=$SECONDS rc=0
  "$@" || rc=$?
  typeset -i elapsed=$(( SECONDS - t0 ))
  if (( rc == 0 )); then
    printf 'PASS\t%s\t%d\t\n' "${name}" "${elapsed}" >> "${junitFile}"
  elif (( rc == 77 )); then
    printf 'SKIP\t%s\t%d\tPreconditions not met; check intentionally not executed\n' \
      "${name}" "${elapsed}" >> "${junitFile}"
    return 0
  else
    printf 'FAIL\t%s\t%d\tFailed (rc=%d); see diagnostics in mtv-migration-verify%s-diagnostics/\n' \
      "${name}" "${elapsed}" "${rc}" "${migrationSuffix}" >> "${junitFile}"
  fi
  return "${rc}"
}

# XmlEscape — replace XML special characters for attribute/text values.
function XmlEscape () {
  typeset s="${1}"
  s="${s//&/\&amp;}"
  s="${s//</\&lt;}"
  s="${s//>/\&gt;}"
  s="${s//\"/\&quot;}"
  s="${s//\'/\&apos;}"
  printf '%s' "${s}"
}

# WriteJunit — emit JUnit XML from accumulated junitFile records.
function WriteJunit () {
  [[ -n "${ARTIFACT_DIR}" ]] || return 0
  [[ -f "${junitFile}" ]] || return 0

  typeset xmlFile="${ARTIFACT_DIR}/junit_cclm_migration_verify${migrationSuffix//-/_}.xml"
  mkdir -p "${ARTIFACT_DIR}"

  typeset -i total=0 failures=0 skipped=0 totalTime=0
  typeset status name elapsed failMsg

  while IFS=$'\t' read -r status name elapsed failMsg; do
    (( total++ )) || true
    (( totalTime += elapsed )) || true
    [[ "${status}" == "FAIL" ]] && (( failures++ )) || true
    [[ "${status}" == "SKIP" ]] && (( skipped++ )) || true
  done < "${junitFile}"

  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<testsuites>\n'
    printf '  <testsuite name="cclm-migration-verify%s" tests="%d" failures="%d" skipped="%d" time="%d">\n' \
      "${migrationSuffix}" "${total}" "${failures}" "${skipped}" "${totalTime}"
    while IFS=$'\t' read -r status name elapsed failMsg; do
      typeset escapedName; escapedName="$(XmlEscape "${name}")"
      printf '    <testcase name="%s" classname="cclm-migration-verify%s" time="%d">\n' \
        "${escapedName}" "${migrationSuffix}" "${elapsed}"
      if [[ "${status}" == "FAIL" ]]; then
        typeset escapedMsg; escapedMsg="$(XmlEscape "${failMsg}")"
        printf '      <failure message="%s">%s</failure>\n' \
          "${escapedMsg}" "${escapedMsg}"
      elif [[ "${status}" == "SKIP" ]]; then
        typeset escapedMsg; escapedMsg="$(XmlEscape "${failMsg}")"
        printf '      <skipped message="%s"/>\n' "${escapedMsg}"
      fi
      printf '    </testcase>\n'
    done < "${junitFile}"
    printf '  </testsuite>\n'
    printf '</testsuites>\n'
  } > "${xmlFile}"

  : "JUnit XML written -> ${xmlFile} (${total} tests, ${failures} failures, ${totalTime}s total)"
  rm -f "${junitFile}"
}

trap - ERR

ResolveSpokeKubeconfigs
targetNs="${targetNs:-${MTV_TEST_VM_NAMESPACE}}"

typeset -i verifyStepRc=0
(
  trap OnError ERR

  typeset -i _rc=0
  JStep "Verification: Destination VMIs Running" VerifyMigration || _rc=$?
  JStep "Verification: Destination VM runStrategy" VerifyDestVmsRunStrategy || _rc=$?
  JStep "Verification: Source VMIM Not Failed" VerifySourceVmimNotFailed || _rc=$?
  JStep "Verification: VM SSH Port Probe" VerifyAllVmsSsh || _rc=$?
  JStep "Verification: Destination SSH Login" WaitDestSshReady || _rc=$?
  JStep "Verification: VM Data Integrity" VerifyVmDataIntegrity || _rc=$?
  JStep "Verification: Guest Disk I/O" VerifyGuestDiskIo || _rc=$?
  JStep "Verification: Guest Network Reachability" VerifyGuestNetwork || _rc=$?
  JStep "Verification: PVC Attachment" VerifyPvcAttachment || _rc=$?
  JStep "Verification: PVC Integrity" VerifyPvcIntegrity || _rc=$?
  exit "${_rc}"
) || verifyStepRc=$?

# Always write JUnit XML — on success and on failure.
WriteJunit

if (( verifyStepRc != 0 )); then
  DumpDiagnostics
  exit "${verifyStepRc}"
fi

true
