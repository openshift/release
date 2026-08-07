#!/bin/bash
#
# Verify and remediate CCLM (Cross-Cluster Live Migration) prerequisites on each spoke.
# No-op when CNV_ENABLE_CCLM != "true".
#
# Background — CNV bug CNV-89129 / upstream kubevirt#16264:
#   virt-handler fails to load /etc/virt-handler/clientcertificates/tls.crt because
#   virt-operator does not add the corresponding volume mount to the DaemonSet when the
#   DecentralizedLiveMigration feature gate is enabled.  The Secret
#   (kubevirt-virt-handler-certs) exists and is populated, but is not mounted.
#   Workaround: patch the DaemonSet to mount the Secret at the expected path.
#   Affected: CNV 4.17+ / OCP 4.22 nightly (as of 2026-08).
#   See also: https://github.com/kubevirt/kubevirt/issues/16264
#
# Checks performed (per spoke, in order):
#   1. Check whether /etc/virt-handler/clientcertificates/tls.crt is already present.
#      If so, skip straight to Service/ServiceExport creation.
#   2. Apply the DaemonSet workaround patch (CNV-89129):
#      a. Scale virt-operator to 0 to prevent it from reconciling away the patch.
#      b. Patch virt-handler DaemonSet to mount the CNV_CCLM_VIRT_HANDLER_CERT_SECRET
#         Secret at /etc/virt-handler/clientcertificates.
#      c. Rollout restart the DaemonSet so all pods pick up the new volume mount.
#      d. Wait for the rollout to complete.
#      e. Verify the cert is present in ALL virt-handler pods.
#      f. INTENTIONALLY leave virt-operator at 0 replicas so it cannot reconcile the
#         patch away during the migration test.  The caller (post chain) is responsible
#         for restoring virt-operator replicas via p2p-cnv-restore-virt-operator.
#      NOTE: virt-operator remaining at 0 does not affect existing virt-handler /
#         virt-controller / virt-api pods — they continue running.  Certificate rotation
#         may pause, but it is safe for the ~1–2 h test window.
#   3. Ensure a Service named virt-synchronization-controller on port CNV_CCLM_SYNC_PORT
#      exists in openshift-cnv (created by `oc apply` — idempotent).
#   4. Ensure a ServiceExport for that Service exists (allows Submariner to propagate it
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

# ScaleVirtOperator — scale virt-operator to desired replicas and wait for rollout.
ScaleVirtOperator() {
    typeset kubeconfig="${1:?}"
    typeset clusterName="${2:?}"
    typeset -i replicas="${3:?}"
    : "[${clusterName}] Scaling virt-operator to ${replicas} replica(s)"
    oc --kubeconfig="${kubeconfig}" scale deployment/virt-operator \
        -n "${cnvNs}" --replicas="${replicas}"
    oc --kubeconfig="${kubeconfig}" rollout status deployment/virt-operator \
        -n "${cnvNs}" --timeout=5m 1>/dev/null || true
    true
}

# GetVirtOperatorReplicas — return the current desired replica count of virt-operator.
GetVirtOperatorReplicas() {
    typeset kubeconfig="${1:?}"
    oc --kubeconfig="${kubeconfig}" get deployment/virt-operator \
        -n "${cnvNs}" \
        -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "2"
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

# CheckVirtHandlerClientCert — return 0 only when ALL Running virt-handler pods have the cert.
# Checking a single pod is insufficient: after a rollout some pods may be on the new
# spec (with the mount) while others are still on the old spec.
CheckVirtHandlerClientCert() {
    typeset kubeconfig="${1:?}"
    typeset -a pods=()
    mapfile -t pods < <(
        oc --kubeconfig="${kubeconfig}" get pod \
            -n "${cnvNs}" -l 'kubevirt.io=virt-handler' \
            --field-selector 'status.phase=Running' \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
          | tr ' ' '\n' | grep -v '^$'
    )
    [[ ${#pods[@]} -gt 0 ]] || return 1
    typeset pod
    for pod in "${pods[@]}"; do
        oc --kubeconfig="${kubeconfig}" exec -n "${cnvNs}" "${pod}" -- \
            test -f "${clientCertMountPath}/tls.crt" 2>/dev/null || return 1
    done
    return 0
}

# PatchVirtHandlerDaemonSetCertMount — add clientcertificates volume mount (idempotent).
# Workaround for CNV-89129: virt-operator does not add the CCLM client cert mount even
# after the DecentralizedLiveMigration feature gate is enabled.
#
# CRITICAL: virt-operator must be scaled to 0 BEFORE patching.  If left running it will
# reconcile the DaemonSet within seconds and remove the patch (observed behaviour on
# CNV 4.17 / OCP 4.22 nightly).  The caller is responsible for restoring virt-operator
# replicas after the cert is verified.
PatchVirtHandlerDaemonSetCertMount() {
    typeset kubeconfig="${1:?}"
    typeset clusterName="${2:?}"
    typeset -i originalReplicas
    originalReplicas="$(GetVirtOperatorReplicas "${kubeconfig}")"

    # Idempotency: skip if mount already present in DaemonSet spec.
    typeset existingMountCount=0
    existingMountCount="$(oc --kubeconfig="${kubeconfig}" get ds virt-handler \
        -n "${cnvNs}" \
        -o jsonpath-as-json='{.spec.template.spec.containers[*].volumeMounts[*].mountPath}' \
        2>/dev/null | jq --arg p "${clientCertMountPath}" '[.[] | select(. == $p)] | length')"
    if ((existingMountCount > 0)); then
        : "[${clusterName}] ${clientCertMountPath} already in DaemonSet spec — skipping patch"
        return 0
    fi

    # Verify the source Secret exists before patching.
    oc --kubeconfig="${kubeconfig}" get secret "${CNV_CCLM_VIRT_HANDLER_CERT_SECRET}" \
        -n "${cnvNs}" 1>/dev/null

    # Scale virt-operator to 0 so it cannot reconcile the patch away.
    ScaleVirtOperator "${kubeconfig}" "${clusterName}" 0

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
    # Explicitly restart to guarantee the DaemonSet controller evicts old pods.
    # Without this, rollout status can return for the previous generation before
    # the controller has processed the patch, leaving old pods (without the new mount)
    # in place for the post-patch cert check.
    oc --kubeconfig="${kubeconfig}" rollout restart ds/virt-handler -n "${cnvNs}"
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

# DeployWatchdogDeployment — deploy an in-cluster watchdog Deployment that keeps
# virt-operator at 0 replicas and re-patches the virt-handler DaemonSet whenever
# OLM's CSV reconciler scales virt-operator back up and it removes the cert mount.
#
# Why a cluster-side pod and not a background process in this step:
#   Each CI step runs in its own ephemeral container.  A background process started
#   here would be killed when this step's container exits.  A Deployment inside the
#   spoke cluster survives across all subsequent step containers.
#
# The watchdog is cleaned up by p2p-cnv-restore-virt-operator (post phase).
# Idempotent: safe to call multiple times.
DeployWatchdogDeployment() {
    typeset kubeconfig="${1:?}"
    typeset clusterName="${2:?}"
    : "[${clusterName}] Deploying CCLM cert watchdog in ${cnvNs}"

    # All YAML values are constants — use quoted heredoc to prevent outer-shell
    # variable expansion so the inner bash script is stored verbatim in the ConfigMap.
    oc --kubeconfig="${kubeconfig}" apply -f - <<'ocWatchdogEOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cclm-watchdog-script
  namespace: openshift-cnv
data:
  watchdog.sh: |
    #!/bin/bash
    # CNV-89129 cert watchdog:
    # Keeps virt-operator at 0 replicas and re-patches virt-handler DaemonSet
    # whenever OLM's CSV reconciler scales virt-operator back up.
    readonly CERT_VOL="cnv-cclm-virt-handler-client-certs"
    readonly NS="openshift-cnv"
    readonly PATCH='[{"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"cnv-cclm-virt-handler-client-certs","secret":{"secretName":"kubevirt-virt-handler-certs","optional":true,"defaultMode":420}}},{"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"cnv-cclm-virt-handler-client-certs","mountPath":"/etc/virt-handler/clientcertificates","readOnly":true}}]'
    while true; do
      sleep 30
      VO=$(oc get deployment virt-operator -n "${NS}" \
        -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
      if [[ "${VO}" != "0" ]]; then
        oc scale deployment virt-operator -n "${NS}" --replicas=0 2>/dev/null || true
      fi
      HAS=$(oc get ds virt-handler -n "${NS}" \
        -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}' \
        2>/dev/null | grep -c "^${CERT_VOL}$" || echo "0")
      if [[ "${HAS}" == "0" ]]; then
        oc scale deployment virt-operator -n "${NS}" --replicas=0 2>/dev/null || true
        oc patch ds virt-handler -n "${NS}" --type=json --patch "${PATCH}" 2>/dev/null || true
        oc rollout restart ds/virt-handler -n "${NS}" 2>/dev/null || true
      fi
    done
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cclm-watchdog
  namespace: openshift-cnv
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: cclm-watchdog
  namespace: openshift-cnv
rules:
- apiGroups: ["apps"]
  resources: ["deployments/scale"]
  verbs: ["get", "update"]
- apiGroups: ["apps"]
  resources: ["daemonsets"]
  verbs: ["get", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: cclm-watchdog
  namespace: openshift-cnv
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: cclm-watchdog
subjects:
- kind: ServiceAccount
  name: cclm-watchdog
  namespace: openshift-cnv
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cclm-watchdog
  namespace: openshift-cnv
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cclm-watchdog
  template:
    metadata:
      labels:
        app: cclm-watchdog
    spec:
      serviceAccountName: cclm-watchdog
      containers:
      - name: watchdog
        image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
        imagePullPolicy: Always
        command: ["/bin/bash", "/scripts/watchdog.sh"]
        volumeMounts:
        - name: scripts
          mountPath: /scripts
          readOnly: true
      volumes:
      - name: scripts
        configMap:
          name: cclm-watchdog-script
          defaultMode: 493
ocWatchdogEOF

    # Non-fatal: if watchdog pod doesn't become available, virt-operator is still
    # at 0 from PatchVirtHandlerDaemonSetCertMount — some protection is better than none.
    oc --kubeconfig="${kubeconfig}" wait deployment/cclm-watchdog \
        -n "${cnvNs}" \
        --for=condition=Available \
        --timeout=3m 1>/dev/null || \
        : "[${clusterName}] WARN: watchdog Deployment not yet Available (may still be pulling image)"
    : "[${clusterName}] CCLM cert watchdog deployed — will keep virt-operator=0 and re-patch DS"
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
    oc --kubeconfig="${kubeconfig}" get deployment/cclm-watchdog \
        -n "${cnvNs}" -o wide > "${diagDir}/cclm-watchdog-deployment.txt" 2>&1 || true
    oc --kubeconfig="${kubeconfig}" get pod \
        -n "${cnvNs}" -l 'app=cclm-watchdog' \
        -o wide > "${diagDir}/cclm-watchdog-pods.txt" 2>&1 || true
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
    typeset -i originalReplicas
    originalReplicas="$(GetVirtOperatorReplicas "${kc}")"
    typeset virtOperatorRestored=false

    # ── Step 1: check if cert already present (fast path — no patching needed) ──
    typeset isCertOk=false
    if CheckVirtHandlerClientCert "${kc}"; then
        isCertOk=true
        : "[${spkName}] virt-handler CCLM client cert already present — skipping patch"
    fi

    # ── Step 2: apply DaemonSet workaround patch if cert absent (CNV-89129) ──
    # virt-operator MUST be scaled to 0 before patching to prevent immediate reconciliation.
    if [[ "${isCertOk}" != "true" ]]; then
        : "[${spkName}] Cert absent — applying DaemonSet workaround patch (CNV-89129)"
        if ! PatchVirtHandlerDaemonSetCertMount "${kc}" "${spkName}"; then
            : "[${spkName}] DaemonSet patch failed"
            SaveCclmReadinessDiagnostics "${kc}" "${spkName}"
            # Restore virt-operator before moving on so the cluster stays functional.
            ScaleVirtOperator "${kc}" "${spkName}" "${originalReplicas}" || true
            (( ++failedCount ))
            continue
        fi
        WaitVirtHandlerRollout "${kc}" "${spkName}" "10m"

        typeset -i certWaitSecs=0
        while (( certWaitSecs < 300 )); do
            if CheckVirtHandlerClientCert "${kc}"; then
                isCertOk=true
                break
            fi
            : "[${spkName}] Post-patch poll for virt-handler cert (${certWaitSecs}/300s)"
            sleep "${pollIntervalSecs}"
            (( certWaitSecs += pollIntervalSecs ))
        done

        # On failure: restore virt-operator so the cluster stays operational.
        # On SUCCESS: intentionally leave virt-operator at 0 so it cannot reconcile the
        # patch away during the migration test.  p2p-cnv-restore-virt-operator (post chain)
        # is responsible for scaling it back up after both migrations complete.
        if [[ "${isCertOk}" != "true" ]]; then
            ScaleVirtOperator "${kc}" "${spkName}" "${originalReplicas}" || true
            virtOperatorRestored=true
        fi
    fi

    if [[ "${isCertOk}" != "true" ]]; then
        : "[${spkName}] FATAL: ${clientCertMountPath}/tls.crt absent in one or more virt-handler pods after all remediation"
        SaveCclmReadinessDiagnostics "${kc}" "${spkName}"
        (( ++failedCount ))
        continue
    fi
    : "[${spkName}] virt-handler CCLM client cert present in all Running pods — virt-operator left at 0 replicas until p2p-cnv-restore-virt-operator runs"

    # ── Step 3: ensure Service on CNV_CCLM_SYNC_PORT ──
    if ! EnsureVirtSyncService "${kc}" "${spkName}"; then
        : "[${spkName}] WARN: failed to ensure virt-synchronization-controller Service"
        (( ++failedCount ))
    fi

    # ── Step 4: ensure ServiceExport (no-op if Submariner CRD not available) ──
    EnsureVirtSyncServiceExport "${kc}" "${spkName}" || true

    # ── Step 5: deploy in-cluster watchdog to survive step-container boundaries ──
    # OLM's CSV reconciler can scale virt-operator back from 0 to its desired
    # replica count even hours after this step exits.  A background process here
    # would be killed when this step's container terminates.  Instead, deploy a
    # Deployment INSIDE the spoke cluster: it survives across all subsequent CI
    # step containers and is cleaned up by p2p-cnv-restore-virt-operator.
    DeployWatchdogDeployment "${kc}" "${spkName}" || \
        : "[${spkName}] WARN: watchdog deploy failed — virt-operator still at 0 as fallback"

    : "[${spkName}] CCLM readiness checks complete"
done

(( failedCount == 0 ))
: "CCLM readiness checks passed on all ${spokeCount} spoke(s)"
true
