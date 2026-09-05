#!/bin/bash
#
# Verify post-migration VM state produced by p2p-mtv-execute-live-migration.
#
# Checks (all hard-fail; recorded as JUnit cases):
#   destination VMIs Running; destination VM runStrategy==Always (OCPBUGS-101771);
#   source VMIM not Failed (OCPBUGS-99403); SSH port 22 from a peer virt-launcher;
#   cloud-init data integrity marker via QEMU Guest Agent; guest disk I/O;
#   guest-level ping to a peer VM.
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
typeset migrationSuffix="${MTV_MIGRATION_SUFFIX:-}"
typeset diagDir=""

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
        printf 'test-vm-%d' "${idx}"
    fi
    true
}

# HubOc — run oc against the ACM hub.
function HubOc () {
    oc --kubeconfig="${KUBECONFIG}" "$@"
}

# SourceOc — run oc against the source spoke.
function SourceOc () {
    oc --kubeconfig="${sourceKubeconfig}" "$@"
}

# DestOc — run oc against the destination spoke.
function DestOc () {
    oc --kubeconfig="${destKubeconfig}" "$@"
}

# ResolveSpokeKubeconfigs — source and destination spoke admin kubeconfigs.
function ResolveSpokeKubeconfigs () {
    [[ -n "${SHARED_DIR}" ]]

    if [[ -z "${sourceKubeconfig}" ]]; then
        if [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig-${sourceSpokeIndex}" ]]; then
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
        if [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig-${destSpokeIndex}" ]]; then
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
function DumpDiagnostics () {
    [[ -n "${ARTIFACT_DIR}" ]] || return 0
    diagDir="${ARTIFACT_DIR}/mtv-migration-verify${migrationSuffix}-diagnostics"
    mkdir -p "${diagDir}"
    HubOc get plan,migration -n "${MTV_NAMESPACE}" \
        > "${diagDir}/hub-mtv-resources.txt" 2>&1 || true
    HubOc get events -n "${MTV_NAMESPACE}" --sort-by='.lastTimestamp' \
        > "${diagDir}/hub-mtv-events.txt" 2>&1 || true

    typeset -i k
    for (( k = 1; k <= vmCount; k++ )); do
        typeset vn
        vn="$(VmName "${k}")"
        SourceOc get "virtualmachine/${vn}" "virtualmachineinstance/${vn}" \
            -n "${MTV_TEST_VM_NAMESPACE}" -o wide > "${diagDir}/source-vm-${vn}.txt" 2>&1 || true
        DestOc get "virtualmachine/${vn}" "virtualmachineinstance/${vn}" \
            -n "${targetNs}" -o wide > "${diagDir}/dest-vm-${vn}.txt" 2>&1 || true
        SourceOc get vmim -n "${MTV_TEST_VM_NAMESPACE}" -o json \
            | jq 'del(.items[].metadata.annotations,.items[].metadata.managedFields)' \
            > "${diagDir}/source-vmim-${vn}.json" 2>&1 || true
        DestOc get vmim -n "${targetNs}" -o json \
            | jq 'del(.items[].metadata.annotations,.items[].metadata.managedFields)' \
            > "${diagDir}/dest-vmim-${vn}.json" 2>&1 || true
    done
    DestOc get pods -n "${targetNs}" \
        > "${diagDir}/dest-pods.txt" 2>&1 || true
    SourceOc get pods -n "${MTV_CNV_NAMESPACE}" -o wide \
        > "${diagDir}/source-cnv-pods.txt" 2>&1 || true
    DestOc get pods -n "${MTV_CNV_NAMESPACE}" -o wide \
        > "${diagDir}/dest-cnv-pods.txt" 2>&1 || true
    DestOc get datavolume,pvc -n "${targetNs}" -o wide \
        > "${diagDir}/dest-storage.txt" 2>&1 || true
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

    oc --kubeconfig="${kc}" get vmim -n "${ns}" -o json \
        | jq -r --arg vm "${vmName}" \
            'first(.items[] | select(.spec.vmiName == $vm) | .status.phase) // ""' \
        || true
}

# VerifyMigration — all destination VMIs must be Running after migration.
function VerifyMigration () {
    typeset -i i
    typeset vmName destPhase

    for (( i = 1; i <= vmCount; i++ )); do
        vmName="$(VmName "${i}")"
        destPhase="$(DestOc get "virtualmachineinstance/${vmName}" -n "${targetNs}" \
            -o jsonpath='{.status.phase}' || true)"
        [[ "${destPhase}" == "Running" ]] \
            || { : "VMI ${vmName} not Running on destination (phase=${destPhase})"; false; }
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
        [[ "${strategy}" == "Always" ]] \
            || { : "VM ${vmName} runStrategy='${strategy}', expected 'Always' (OCPBUGS-101771)"; false; }
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
        srcVmimPhase="$(VmimPhase "${sourceKubeconfig}" "${MTV_TEST_VM_NAMESPACE}" "${vmName}")"
        [[ "${srcVmimPhase}" != "Failed" ]] \
            || { : "Source VMIM for ${vmName} is Failed — false-positive migration (OCPBUGS-99403)"; false; }
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
            : "FAIL: no probe anchor for SSH check on ${vmName}"
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
            2) : "FAIL: no IP on VMI ${vmName} for SSH probe"
               (( ++failed )) ;;
            *) : "FAIL: SSH port 22 not reachable on ${vmName} (rc=${probeRc})"
               (( ++failed )) ;;
        esac
    done

    (( failed == 0 ))
}

# VirtctlReadVmFile — read a file from a KubeVirt VM via QEMU Guest Agent.
# Requires qemu-guest-agent in the VM and libvirt/virsh in the virt-launcher
# compute container (KubeVirt 1.x / OCP CNV 4.14+).
# All oc exec calls run under set +x: pod/domain names are internal identifiers
# that must not appear in xtrace logs.
# Exit codes:
#   0 — file read successfully (content on stdout)
#   1 — QEMU GA infrastructure unavailable (virsh not found, domain not listed,
#       QEMU GA not reachable); caller should skip the VM gracefully.
#   2 — QEMU GA responded but guest command failed (file not found, permission
#       denied, /bin/cat exited non-zero); caller should treat as integrity failure.
function VirtctlReadVmFile () {
    typeset launcherPod="${1:?}"; (($#)) && shift
    typeset ns="${1:?}"; (($#)) && shift
    typeset kc="${1:?}"; (($#)) && shift
    typeset filePath="${1:?}"; (($#)) && shift

    ( set +x
      # Discover the libvirt domain name; KubeVirt runs one VM per pod.
      typeset domain
      domain="$(oc --kubeconfig="${kc}" exec -n "${ns}" "${launcherPod}" -c compute -- \
          bash -c 'virsh -c qemu:///system list --all --name 2>/dev/null \
                       | grep -v "^[[:space:]]*$" | head -1' \
          || true)"
      [[ -n "${domain}" ]] || exit 1

      # Invoke /bin/cat inside the guest via QEMU GA guest-exec; returns async PID.
      typeset execJson
      execJson="{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"/bin/cat\",\"arg\":[\"${filePath}\"],\"capture-output\":true}}"
      typeset execResult
      execResult="$(oc --kubeconfig="${kc}" exec -n "${ns}" "${launcherPod}" -c compute -- \
          virsh -c qemu:///system qemu-agent-command "${domain}" "${execJson}")" || exit 1

      typeset pid
      pid="$(printf '%s' "${execResult}" | jq -r '.return.pid // empty')"
      [[ -n "${pid}" ]] || exit 1

      # Poll guest-exec-status until exited=true (QEMU GA is asynchronous).
      typeset statusJson
      statusJson="{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":${pid}}}"
      typeset statusResult=""
      typeset -i attempts=0 completed=0
      while (( attempts < 10 && completed == 0 )); do
          sleep 1
          statusResult="$(oc --kubeconfig="${kc}" exec -n "${ns}" "${launcherPod}" -c compute -- \
              virsh -c qemu:///system qemu-agent-command "${domain}" "${statusJson}" \
              || true)"
          [[ "$(printf '%s' "${statusResult}" | jq -r '.return.exited // false')" == "true" ]] \
              && completed=1
          (( ++attempts )) || true
      done

      (( completed )) || exit 1

      # Require guest command exited 0; decode base64-encoded stdout.
      # Non-zero exit from /bin/cat means the file is missing or unreadable —
      # distinguish this from an infra failure by exiting 2 so the caller can
      # record it as an integrity failure rather than silently skipping.
      typeset exitcode
      exitcode="$(printf '%s' "${statusResult}" | jq -r '.return.exitcode // 1')"
      [[ "${exitcode}" == "0" ]] || exit 2

      printf '%s' "${statusResult}" | jq -r '.return."out-data" // ""' | base64 -d
      true
    )
}

# VerifyVmDataIntegrity — verify that cloud-init marker files survive migration intact.
# p2p-create-migration-test-vm injects a write_files cloud-init block that writes
# /home/cloud-user/migration-marker.txt with content equal to the VM name.
# This function reads back that file on the destination via QEMU Guest Agent and
# compares it to the expected VM name.
# Gracefully skipped per VM when virsh / QEMU GA is unavailable (e.g. cirros VMs).
# If every VM is skipped, the check fails (no false green). Per-VM failures fail the step.
function VerifyVmDataIntegrity () {
    [[ "${MTV_VM_DATA_INTEGRITY}" == "true" ]] || return 77

    # Disable xtrace for the entire function: pod names, domain identifiers, and
    # marker content are internal values that must not appear in CI logs.
    typeset _wasTracing=''
    [[ $- == *x* ]] && _wasTracing=true || _wasTracing=false
    set +x

    typeset -i i
    typeset -a vmNamesArr=() launcherPodsArr=()
    typeset -i failed=0 skipped=0

    # CollectDestLaunchers runs under set +x and uses the two-strategy pod lookup,
    # which handles post-CCLM pods where kubevirt.io/domain may be absent.
    CollectDestLaunchers vmNamesArr launcherPodsArr

    for (( i = 0; i < vmCount; i++ )); do
        typeset vmName launcherPod
        vmName="${vmNamesArr[${i}]}"
        launcherPod="${launcherPodsArr[${i}]}"
        typeset expectedMarker="${vmName}"

        if [[ -z "${launcherPod}" ]]; then
            printf 'WARN: No Running virt-launcher pod for %s; skipping integrity check\n' \
                "${vmName}" >&2
            (( ++skipped ))
            continue
        fi

        typeset probeRc=0
        typeset actualMarker=""
        actualMarker="$(VirtctlReadVmFile \
            "${launcherPod}" "${targetNs}" "${destKubeconfig}" \
            "/home/cloud-user/migration-marker.txt")" || probeRc=$?

        if (( probeRc == 1 )); then
            # QEMU GA infrastructure not available (virsh/domain unreachable); skip.
            printf 'WARN: Cannot read integrity marker on %s (virsh/QEMU GA unavailable); skipping\n' \
                "${vmName}" >&2
            (( ++skipped ))
            continue
        elif (( probeRc == 2 )); then
            # Guest command ran but marker is missing or unreadable — integrity failure.
            printf 'ERROR: Integrity marker missing or unreadable on %s\n' "${vmName}" >&2
            (( ++failed ))
            continue
        fi

        # Strip any trailing newline that cloud-init or base64-d may append.
        typeset trimmedMarker="${actualMarker%$'\n'}"

        if [[ "${trimmedMarker}" == "${expectedMarker}" ]]; then
            : "Data integrity verified for ${vmName}"
        else
            # Log only a mismatch indicator — never log raw marker content.
            printf 'ERROR: Data integrity FAIL for %s (marker mismatch)\n' "${vmName}" >&2
            (( ++failed ))
        fi
    done

    [[ "${_wasTracing}" == "true" ]] && set -x

    # All VMs skipped means the check never ran — that is a false green, not a pass.
    (( skipped == vmCount )) && {
        : "FAIL: data integrity skipped on all ${vmCount} VMs (QEMU GA unavailable?)"
        false
    }

    (( failed == 0 ))
}

# VirtctlGuestExec — run a guest command via QEMU Guest Agent (path + JSON arg array).
# argJson must be a JSON array of strings, e.g. '["-c","sync"].
# Exit 1 = GA infra unavailable; exit 2 = guest command non-zero; 0 = success.
# stdout is the guest command stdout (decoded). Runs under set +x.
function VirtctlGuestExec () {
    typeset launcherPod="${1:?}"; (($#)) && shift
    typeset ns="${1:?}"; (($#)) && shift
    typeset kc="${1:?}"; (($#)) && shift
    typeset guestPath="${1:?}"; (($#)) && shift
    typeset argJson="${1:?}"; (($#)) && shift

    ( set +x
      typeset domain
      domain="$(oc --kubeconfig="${kc}" exec -n "${ns}" "${launcherPod}" -c compute -- \
          bash -c 'virsh -c qemu:///system list --all --name 2>/dev/null \
                       | grep -v "^[[:space:]]*$" | head -1' \
          || true)"
      [[ -n "${domain}" ]] || exit 1

      typeset execJson
      execJson="$(jq -cn --arg path "${guestPath}" --argjson arg "${argJson}" \
          '{execute:"guest-exec", arguments:{path:$path, arg:$arg, "capture-output":true}}')"
      typeset execResult
      execResult="$(oc --kubeconfig="${kc}" exec -n "${ns}" "${launcherPod}" -c compute -- \
          virsh -c qemu:///system qemu-agent-command "${domain}" "${execJson}")" || exit 1

      typeset pid
      pid="$(printf '%s' "${execResult}" | jq -r '.return.pid // empty')"
      [[ -n "${pid}" ]] || exit 1

      typeset statusJson
      statusJson="$(jq -cn --argjson pid "${pid}" \
          '{execute:"guest-exec-status", arguments:{pid:$pid}}')"
      typeset statusResult=""
      typeset -i attempts=0 completed=0
      while (( attempts < 20 && completed == 0 )); do
          sleep 1
          statusResult="$(oc --kubeconfig="${kc}" exec -n "${ns}" "${launcherPod}" -c compute -- \
              virsh -c qemu:///system qemu-agent-command "${domain}" "${statusJson}" \
              || true)"
          [[ "$(printf '%s' "${statusResult}" | jq -r '.return.exited // false')" == "true" ]] \
              && completed=1
          (( ++attempts )) || true
      done
      (( completed )) || exit 1

      typeset exitcode
      exitcode="$(printf '%s' "${statusResult}" | jq -r '.return.exitcode // 1')"
      [[ "${exitcode}" == "0" ]] || exit 2

      printf '%s' "${statusResult}" | jq -r '.return."out-data" // ""' | base64 -d
      true
    )
}

# CollectDestLaunchers — fill nameref arrays of VM names and Running virt-launcher pods.
# Runs under set +x: pod names are internal cluster identifiers that must not appear
# in CI logs via xtrace variable-assignment tracing.
#
# Pod lookup uses two strategies to handle label differences after CCLM migration:
#   1. kubevirt.io/domain=<vmname> label (standard KubeVirt label; may be absent post-CCLM).
#   2. Pod name prefix virt-launcher-<vmname>- (fallback; matches proven GetSourceVirtLauncherPod
#      pattern used in p2p-mtv-execute-hub-spoke-migration-commands.sh).
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
            | jq -r --arg d "${vmn}" \
                'first(.items[]
                 | select(.metadata.labels["kubevirt.io/domain"]==$d)
                 | select(.status.phase=="Running")
                 | .metadata.name) // ""' \
            || true)"

        # Strategy 2: pod name prefix fallback (post-CCLM pods may lack the domain label).
        if [[ -z "${pod}" ]]; then
            pod="$(printf '%s' "${podsJson}" \
                | jq -r --arg n "${vmn}" \
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
# Skipped (SKIP JUnit record, rc=77) when MTV_VM_GUEST_EXEC=false (e.g. cirros VMs that
# do not ship a QEMU Guest Agent).
function VerifyGuestDiskIo () {
    [[ "${vmGuestExec}" == "true" ]] || return 77
    typeset -a vmNamesArr=() launcherPodsArr=()
    CollectDestLaunchers vmNamesArr launcherPodsArr

    typeset -i i failed=0
    typeset ioCmd='dd if=/dev/zero of=/tmp/cclm-io.bin bs=1M count=4 conv=fsync status=none && sha256sum /tmp/cclm-io.bin && rm -f /tmp/cclm-io.bin'
    typeset argJson
    argJson="$(jq -cn --arg c "${ioCmd}" '["-c", $c]')"

    for (( i = 0; i < vmCount; i++ )); do
        typeset vmName launcherPod
        vmName="${vmNamesArr[${i}]}"
        launcherPod="${launcherPodsArr[${i}]}"
        if [[ -z "${launcherPod}" ]]; then
            : "FAIL: no Running virt-launcher for disk I/O check on ${vmName}"
            (( ++failed ))
            continue
        fi
        typeset probeRc=0
        VirtctlGuestExec "${launcherPod}" "${targetNs}" "${destKubeconfig}" \
            /bin/bash "${argJson}" >/dev/null || probeRc=$?
        case "${probeRc}" in
            0) : "Guest disk I/O succeeded on ${vmName}" ;;
            1) : "FAIL: QEMU GA unavailable for disk I/O on ${vmName}"
               (( ++failed )) ;;
            *) : "FAIL: guest disk I/O command failed on ${vmName} (rc=${probeRc})"
               (( ++failed )) ;;
        esac
    done

    (( failed == 0 ))
}

# VerifyGuestNetwork — ping a peer VM IP from inside each guest (guest-level reachability).
# Distinct from the SSH TCP probe which runs in the virt-launcher pod, not the guest.
# Skipped (SKIP JUnit record, rc=77) for vmCount=1 (no peer) or when MTV_VM_GUEST_EXEC=false.
function VerifyGuestNetwork () {
    [[ "${vmGuestExec}" == "true" ]] || return 77
    (( vmCount > 1 )) || return 77

    typeset -a vmNamesArr=() launcherPodsArr=()
    CollectDestLaunchers vmNamesArr launcherPodsArr

    typeset -i i failed=0
    for (( i = 0; i < vmCount; i++ )); do
        typeset vmName launcherPod
        vmName="${vmNamesArr[${i}]}"
        launcherPod="${launcherPodsArr[${i}]}"
        typeset -i peerIdx=$(( (i + 1) % vmCount ))
        typeset peerName="${vmNamesArr[${peerIdx}]}"

        if [[ -z "${launcherPod}" ]]; then
            : "FAIL: no Running virt-launcher for guest network check on ${vmName}"
            (( ++failed ))
            continue
        fi

        typeset probeRc=0
        ( set +x
          typeset peerIp
          peerIp="$(DestOc get "virtualmachineinstance/${peerName}" -n "${targetNs}" \
              -o jsonpath='{.status.interfaces[0].ipAddress}' || true)"
          [[ -n "${peerIp}" ]] || exit 2
          typeset argJson
          argJson="$(jq -cn --arg ip "${peerIp}" '["-c", ("ping -c 2 -W 5 " + $ip)]')"
          VirtctlGuestExec "${launcherPod}" "${targetNs}" "${destKubeconfig}" \
              /bin/bash "${argJson}" >/dev/null
        ) || probeRc=$?

        case "${probeRc}" in
            0) : "Guest ping to peer succeeded on ${vmName}" ;;
            2) : "FAIL: no IP on peer VMI for guest network check on ${vmName}"
               (( ++failed )) ;;
            *) : "FAIL: guest ping to peer failed on ${vmName} (rc=${probeRc})"
               (( ++failed )) ;;
        esac
    done

    (( failed == 0 ))
}


# JStep — run a function, append PASS/FAIL/SKIP record to junitFile, propagate exit code.
# rc=0:  PASS — check executed and succeeded.
# rc=77: SKIP — preconditions not met; check intentionally not executed.
#               Returns 0 so the ERR trap is not triggered and subsequent steps run.
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
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    s="${s//\'/&apos;}"
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
        printf '<testsuite name="cclm-migration-verify%s" tests="%d" failures="%d" errors="0" skipped="%d" time="%d">\n' \
            "${migrationSuffix}" "${total}" "${failures}" "${skipped}" "${totalTime}"
        while IFS=$'\t' read -r status name elapsed failMsg; do
            typeset escapedName; escapedName="$(XmlEscape "${name}")"
            printf '  <testcase name="%s" classname="cclm-migration-verify%s" time="%d">\n' \
                "${escapedName}" "${migrationSuffix}" "${elapsed}"
            if [[ "${status}" == "FAIL" ]]; then
                typeset escapedMsg; escapedMsg="$(XmlEscape "${failMsg}")"
                printf '    <failure message="%s">%s</failure>\n' \
                    "${escapedMsg}" "${escapedMsg}"
            elif [[ "${status}" == "SKIP" ]]; then
                typeset escapedMsg; escapedMsg="$(XmlEscape "${failMsg}")"
                printf '    <skipped message="%s"/>\n' "${escapedMsg}"
            fi
            printf '  </testcase>\n'
        done < "${junitFile}"
        printf '</testsuite>\n'
    } > "${xmlFile}"

    : "JUnit XML written -> ${xmlFile} (${total} tests, ${failures} failures, ${totalTime}s total)"
    rm -f "${junitFile}"
}

trap - ERR

typeset -i verifyStepRc=0
(
    trap OnError ERR

    ResolveSpokeKubeconfigs
    targetNs="${targetNs:-${MTV_TEST_VM_NAMESPACE}}"

    JStep "Verification: Destination VMIs Running"   VerifyMigration
    JStep "Verification: Destination VM runStrategy" VerifyDestVmsRunStrategy
    JStep "Verification: Source VMIM Not Failed"     VerifySourceVmimNotFailed
    JStep "Verification: VM SSH Port Probe"          VerifyAllVmsSsh
    JStep "Verification: VM Data Integrity"          VerifyVmDataIntegrity
    JStep "Verification: Guest Disk I/O"             VerifyGuestDiskIo
    JStep "Verification: Guest Network Reachability" VerifyGuestNetwork
    true
) || verifyStepRc=$?

# Always write JUnit XML — on success and on failure.
WriteJunit

if (( verifyStepRc != 0 )); then
    DumpDiagnostics
    exit "${verifyStepRc}"
fi

true
