#!/bin/bash
#
# Verify and remediate CCLM (Cross-Cluster Live Migration) prerequisites on each spoke.
# No-op when CNV_ENABLE_CCLM != "true".
#
# Checks performed (per spoke, in order):
#   1. Restart virt-operator to trigger DaemonSet reconciliation.  Required when the
#      DecentralizedLiveMigration feature gate does not cause virt-operator to add
#      the /etc/virt-handler/clientcertificates volume mount at install time (observed
#      on CNV 4.17+ / OCP 4.22 nightly — treated as an operator reconciliation lag).
#   2. Wait for virt-handler DaemonSet rollout to complete.
#   3. Poll until /etc/virt-handler/clientcertificates/tls.crt appears in a
#      virt-handler pod (up to CNV_CCLM_WAIT_TIMEOUT seconds).
#   4. Fallback: if cert still absent, patch virt-handler DaemonSet to mount the
#      CNV_CCLM_VIRT_HANDLER_CERT_SECRET Secret at /etc/virt-handler/clientcertificates.
#      Collects diagnostics and fails the step if cert is still absent after the patch.
#   5. Ensure a Service named virt-synchronization-controller on port CNV_CCLM_SYNC_PORT
#      exists in openshift-cnv (created by `oc apply` — idempotent).
#   6. Ensure a ServiceExport for that Service exists (allows Submariner to propagate it
#      to other clusters).  Skipped gracefully when the ServiceExport CRD is not yet
#      installed (i.e. Submariner is not up yet on this spoke).
#
set -euxo pipefail; shopt -s inherit_errexit

[[ "${CNV_ENABLE_CCLM}" == "true" ]] || {
    : "CNV_ENABLE_CCLM is not 'true' — CCLM readiness checks skipped"
    true; exit 0
}

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

readonly cnvNs="openshift-cnv"
readonly clientCertMountPath="/etc/virt-handler/clientcertificates"
typeset -i waitTimeoutSecs="${CNV_CCLM_WAIT_TIMEOUT}"
typeset -i pollIntervalSecs=15

# LoadSpokeKubeconfigs — output spoke kubeconfig paths (one per line).
LoadSpokeKubeconfigs() {
    typeset -a kcsArr=()
    typeset -i i
    for ((i = 1; ; i++)); do
        typeset kcPath="${SHARED_DIR}/managed-cluster-kubeconfig-${i}"
        [[ -f "${kcPath}" ]] || break
        kcsArr+=("${kcPath}")
    done
    if [[ ${#kcsArr[@]} -eq 0 && -f "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
        kcsArr+=("${SHARED_DIR}/managed-cluster-kubeconfig")
    fi
    ((${#kcsArr[@]} > 0))
    printf '%s\n' "${kcsArr[@]}"
}

# GetSpokeClusterName — return cluster name for 1-based spoke index.
GetSpokeClusterName() {
    typeset -i idx="${1:?}"
    typeset nameFile="${SHARED_DIR}/managed-cluster-name-${idx}"
    if [[ -f "${nameFile}" ]]; then
        cat "${nameFile}"
    else
        printf 'spoke-%d' "${idx}"
    fi
}

# RestartVirtOperatorAndWait — restart virt-operator and wait for rollout.
RestartVirtOperatorAndWait() {
    typeset kubeconfig="${1:?}"
    typeset clusterName="${2:?}"
    : "[${clusterName}] Restarting virt-operator to trigger DaemonSet reconciliation"
    oc --kubeconfig="${kubeconfig}" rollout restart deployment/virt-operator \
        -n "${cnvNs}"
    oc --kubeconfig="${kubeconfig}" rollout status deployment/virt-operator \
        -n "${cnvNs}" --timeout=5m 1>/dev/null
    true
}

# WaitVirtHandlerRollout — wait for virt-handler DaemonSet rollout (non-fatal on timeout).
WaitVirtHandlerRollout() {
    typeset kubeconfig="${1:?}"
    typeset clusterName="${2:?}"
    typeset timeout="${3:-10m}"
    : "[${clusterName}] Waiting for virt-handler DaemonSet rollout (timeout=${timeout})"
    oc --kubeconfig="${kubeconfig}" rollout status ds/virt-handler \
        -n "${cnvNs}" --timeout="${timeout}" 1>/dev/null || true
    true
}

# CheckVirtHandlerClientCert — return 0 if any virt-handler pod has the CCLM client cert.
CheckVirtHandlerClientCert() {
    typeset kubeconfig="${1:?}"
    typeset podName=""
    podName="$(oc --kubeconfig="${kubeconfig}" get pod \
        -n "${cnvNs}" -l 'kubevirt.io=virt-handler' \
        -o jsonpath-as-json='{.items[*].metadata.name}' \
        2>/dev/null | jq -re '.[0]' || true)"
    [[ -n "${podName}" ]] || return 1
    oc --kubeconfig="${kubeconfig}" exec -n "${cnvNs}" "${podName}" -- \
        test -f "${clientCertMountPath}/tls.crt" 2>/dev/null
}

# PatchVirtHandlerDaemonSetCertMount — add clientcertificates volume mount (idempotent).
# Workaround for virt-operator not reconciling the CCLM client cert mount when
# DecentralizedLiveMigration is enabled.  Uses a unique volume name
# (cnv-cclm-virt-handler-client-certs) to avoid collisions with operator-managed volumes.
PatchVirtHandlerDaemonSetCertMount() {
    typeset kubeconfig="${1:?}"
    typeset clusterName="${2:?}"

    # Idempotency: skip if mount already present.
    typeset existingMountCount=0
    existingMountCount="$(oc --kubeconfig="${kubeconfig}" get ds virt-handler \
        -n "${cnvNs}" \
        -o jsonpath-as-json='{.spec.template.spec.containers[*].volumeMounts[*].mountPath}' \
        2>/dev/null | jq --arg p "${clientCertMountPath}" '[.[] | select(. == $p)] | length')"
    if ((existingMountCount > 0)); then
        : "[${clusterName}] ${clientCertMountPath} already mounted — skipping DaemonSet patch"
        return 0
    fi

    # Verify the source Secret exists before patching.
    oc --kubeconfig="${kubeconfig}" get secret "${CNV_CCLM_VIRT_HANDLER_CERT_SECRET}" \
        -n "${cnvNs}" 1>/dev/null
    : "[${clusterName}] Patching virt-handler DaemonSet: mounting ${CNV_CCLM_VIRT_HANDLER_CERT_SECRET} at ${clientCertMountPath}"
    oc --kubeconfig="${kubeconfig}" patch ds virt-handler \
        -n "${cnvNs}" --type=json \
        --patch "[
          {\"op\":\"add\",
           \"path\":\"/spec/template/spec/volumes/-\",
           \"value\":{\"name\":\"cnv-cclm-virt-handler-client-certs\",
                      \"secret\":{\"secretName\":\"${CNV_CCLM_VIRT_HANDLER_CERT_SECRET}\",
                                  \"optional\":true,
                                  \"defaultMode\":420}}},
          {\"op\":\"add\",
           \"path\":\"/spec/template/spec/containers/0/volumeMounts/-\",
           \"value\":{\"name\":\"cnv-cclm-virt-handler-client-certs\",
                      \"mountPath\":\"${clientCertMountPath}\",
                      \"readOnly\":true}}
        ]"
    true
}

# EnsureVirtSyncService — create Service for port CNV_CCLM_SYNC_PORT if absent.
EnsureVirtSyncService() {
    typeset kubeconfig="${1:?}"
    typeset clusterName="${2:?}"

    if oc --kubeconfig="${kubeconfig}" get svc virt-synchronization-controller \
            -n "${cnvNs}" 1>/dev/null 2>&1; then
        : "[${clusterName}] Service virt-synchronization-controller already exists"
        return 0
    fi

    : "[${clusterName}] Creating Service virt-synchronization-controller:${CNV_CCLM_SYNC_PORT}"
    {
        oc --kubeconfig="${kubeconfig}" create -f - \
            --dry-run=client -o yaml --save-config
    } 0<<ocEOF | oc --kubeconfig="${kubeconfig}" apply -f -
apiVersion: v1
kind: Service
metadata:
  name: virt-synchronization-controller
  namespace: ${cnvNs}
  labels:
    app: virt-synchronization-controller
    kubevirt.io: virt-synchronization-controller
spec:
  selector:
    kubevirt.io: virt-synchronization-controller
  ports:
  - name: sync
    port: ${CNV_CCLM_SYNC_PORT}
    targetPort: ${CNV_CCLM_SYNC_PORT}
    protocol: TCP
ocEOF
    true
}

# EnsureVirtSyncServiceExport — create ServiceExport if absent.
# No-op when the Submariner ServiceExport CRD is not yet installed.
EnsureVirtSyncServiceExport() {
    typeset kubeconfig="${1:?}"
    typeset clusterName="${2:?}"

    # Graceful skip when Submariner ServiceExport CRD is not installed.
    typeset seExists=""
    seExists="$(oc --kubeconfig="${kubeconfig}" get crd \
        serviceexports.multicluster.x-k8s.io \
        --ignore-not-found \
        -o jsonpath='{.metadata.name}' 2>/dev/null || true)"
    if [[ -z "${seExists}" ]]; then
        : "[${clusterName}] ServiceExport CRD not available — skipping"
        return 0
    fi

    if oc --kubeconfig="${kubeconfig}" get serviceexport \
            virt-synchronization-controller \
            -n "${cnvNs}" 1>/dev/null 2>&1; then
        : "[${clusterName}] ServiceExport virt-synchronization-controller already exists"
        return 0
    fi

    : "[${clusterName}] Creating ServiceExport virt-synchronization-controller"
    {
        oc --kubeconfig="${kubeconfig}" create -f - \
            --dry-run=client -o yaml --save-config
    } 0<<'ocEOF' | oc --kubeconfig="${kubeconfig}" apply -f -
apiVersion: multicluster.x-k8s.io/v1alpha1
kind: ServiceExport
metadata:
  name: virt-synchronization-controller
  namespace: openshift-cnv
ocEOF
    true
}

# SaveCclmReadinessDiagnostics — collect diagnostics to ARTIFACT_DIR.
SaveCclmReadinessDiagnostics() {
    typeset kubeconfig="${1:?}"
    typeset clusterName="${2:?}"
    typeset diagDir="${ARTIFACT_DIR}/cclm-readiness-${clusterName}"
    mkdir -p "${diagDir}"

    oc --kubeconfig="${kubeconfig}" get pod \
        -n "${cnvNs}" -l 'kubevirt.io=virt-handler' \
        -o wide > "${diagDir}/virt-handler-pods.txt" 2>&1 || true
    oc --kubeconfig="${kubeconfig}" get ds virt-handler \
        -n "${cnvNs}" -o yaml \
        > "${diagDir}/virt-handler-ds.yaml" 2>&1 || true
    oc --kubeconfig="${kubeconfig}" get secret -n "${cnvNs}" \
        > "${diagDir}/openshift-cnv-secrets-list.txt" 2>&1 || true
    oc --kubeconfig="${kubeconfig}" logs \
        -n "${cnvNs}" deployment/virt-operator \
        --tail=150 > "${diagDir}/virt-operator-logs.txt" 2>&1 || true
    oc --kubeconfig="${kubeconfig}" logs \
        -n "${cnvNs}" -l 'kubevirt.io=virt-handler' \
        --tail=80 > "${diagDir}/virt-handler-logs.txt" 2>&1 || true
    oc --kubeconfig="${kubeconfig}" get svc \
        -n "${cnvNs}" > "${diagDir}/services.txt" 2>&1 || true
    oc --kubeconfig="${kubeconfig}" get serviceexport \
        -n "${cnvNs}" > "${diagDir}/serviceexports.txt" 2>&1 || true
    true
}

# ── main ──────────────────────────────────────────────────────────────────────

typeset -a spokeKubeconfigsArr=()
mapfile -t spokeKubeconfigsArr < <(LoadSpokeKubeconfigs)

typeset -i spokeCount="${#spokeKubeconfigsArr[@]}"
typeset -i failedCount=0 i

: "=== CCLM readiness on ${spokeCount} spoke(s) ==="

for ((i = 0; i < spokeCount; i++)); do
    typeset kc="${spokeKubeconfigsArr[i]}"
    typeset spkName=""
    spkName="$(GetSpokeClusterName "$((i + 1))")"

    # ── Step 1: restart virt-operator ──
    RestartVirtOperatorAndWait "${kc}" "${spkName}"

    # ── Step 2: wait for virt-handler DaemonSet rollout ──
    WaitVirtHandlerRollout "${kc}" "${spkName}" "10m"

    # ── Step 3: poll for CCLM client cert ──
    typeset -i certWaitSecs=0
    typeset isCertOk=false
    while (( certWaitSecs < waitTimeoutSecs )); do
        if CheckVirtHandlerClientCert "${kc}"; then
            isCertOk=true
            break
        fi
        : "[${spkName}] Waiting for virt-handler ${clientCertMountPath}/tls.crt (${certWaitSecs}/${waitTimeoutSecs}s)"
        sleep "${pollIntervalSecs}"
        (( certWaitSecs += pollIntervalSecs ))
    done

    # ── Step 4: fallback DaemonSet patch if cert still absent ──
    if [[ "${isCertOk}" != "true" ]]; then
        : "[${spkName}] Cert absent after virt-operator restart — applying DaemonSet workaround patch"
        if ! PatchVirtHandlerDaemonSetCertMount "${kc}" "${spkName}"; then
            : "[${spkName}] DaemonSet patch failed"
            SaveCclmReadinessDiagnostics "${kc}" "${spkName}"
            (( ++failedCount ))
            continue
        fi
        WaitVirtHandlerRollout "${kc}" "${spkName}" "10m"

        certWaitSecs=0
        isCertOk=false
        while (( certWaitSecs < 300 )); do
            if CheckVirtHandlerClientCert "${kc}"; then
                isCertOk=true
                break
            fi
            : "[${spkName}] Post-patch poll for virt-handler cert (${certWaitSecs}/300s)"
            sleep "${pollIntervalSecs}"
            (( certWaitSecs += pollIntervalSecs ))
        done
    fi

    if [[ "${isCertOk}" != "true" ]]; then
        : "[${spkName}] FATAL: ${clientCertMountPath}/tls.crt absent after all remediation"
        SaveCclmReadinessDiagnostics "${kc}" "${spkName}"
        (( ++failedCount ))
        continue
    fi
    : "[${spkName}] virt-handler CCLM client cert present"

    # ── Step 5: ensure Service on CNV_CCLM_SYNC_PORT ──
    if ! EnsureVirtSyncService "${kc}" "${spkName}"; then
        : "[${spkName}] WARN: failed to ensure virt-synchronization-controller Service"
        (( ++failedCount ))
    fi

    # ── Step 6: ensure ServiceExport (no-op if Submariner CRD not available) ──
    EnsureVirtSyncServiceExport "${kc}" "${spkName}" || true

    : "[${spkName}] CCLM readiness checks complete"
done

(( failedCount == 0 ))
: "CCLM readiness checks passed on all ${spokeCount} spoke(s)"
true
