#!/bin/bash
#
# Prepares the ACM spoke cluster for CNV upgrade tests. Runs before
# interop-tests-openshift-virtualization-upgrade-tests.
#
# Responsibilities:
#   1. Resolve CNV_TARGET_VERSION from spoke packagemanifest (when CNV_TARGET_MAJOR_MINOR is set)
#      and write it to ${SHARED_DIR}/cnv-target-version for the test step to consume.
#   2. Configure the default storage class and ODF volume snapshot class.
#   3. Ensure CDI StorageProfile has RWX Block as the first claimPropertySet.
#   4. Restart ODF RBD CSI and HPP CSI to flush stale volume locks (post-OCP-upgrade).
#   5. Wait for RHEL/Windows boot image DataImportCrons to be UpToDate.
#   6. Prepare OLM install plans so the pending plan targets CNV_TARGET_VERSION.
#   7. Slow down HCO workload update controller so VMIs remain outdated long enough
#      for observability tests to pass (kubevirt_vmi_number_of_outdated metric).
#
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq yq

# Resolve the FIRST (lowest) kubevirt-hyperconverged x.y.z for major.minor from the spoke catalog.
# Used for one-hop upgrade tests where the target is the initial z-stream entry point for the minor
# (e.g. 4.21.0). OLM's upgrade graph provides a direct 'replaces' edge from the latest 4.20.z to
# the first 4.21.z, making this a single-hop upgrade.
ResolveCnvFirstVersion() {
    typeset majorMinor="${1:?}" channel="${2:?}"
    oc get packagemanifest kubevirt-hyperconverged -n openshift-marketplace -o json \
        | jq -r --arg ch "${channel}" --arg prefix "${majorMinor}." '
            .status.channels[]
            | select(.name == $ch)
            | .entries[]
            | select(.version | startswith($prefix))
            | .version' \
        | sort -V | head -n1
}

Retry() {
    typeset -i maxSecs="${1:?}"; (($#)) && shift
    typeset -i delay="${1:?}"; (($#)) && shift

    (
        typeset -i lastExitCode=0
        SECONDS=0
        until "$@"; do
            lastExitCode=$?
            if (( SECONDS >= maxSecs )); then
                exit "${lastExitCode}"
            fi
            : "Command failed. Retrying in ${delay}s (${SECONDS}/${maxSecs}s)"
            sleep "${delay}"
        done
        true
    )
    true
}

SetDefaultStorageClassForCnv() {
    typeset storageClassName="${1:?}"; (($#)) && shift
    oc get "storageclass/${storageClassName}" > /dev/null || {
        printf 'ERROR: StorageClass %s not found (interop-tests-deploy-odf must complete first)\n' \
            "${storageClassName}" >&2
        oc get sc || true
        exit 1
    }
    oc get storageclass -o name | xargs -trI{} oc patch {} -p \
        '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "false", "storageclass.kubevirt.io/is-default-virt-class": "false"}}}'
    oc patch storageclass "${storageClassName}" -p \
        '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true", "storageclass.kubevirt.io/is-default-virt-class": "true"}}}'
    true
}

Cnv__WaitRhelBootImportCronsUpToDate() {
    typeset dvNamespace="${1:?}"; (($#)) && shift
    typeset waitTimeout="${CNV_BOOT_IMPORT_CRON_UPTODATE_WAIT_TIMEOUT}"
    typeset -i appearTimeoutSec=600
    typeset -i deadline=$((SECONDS + appearTimeoutSec))
    typeset -a bootCrons=()
    typeset cronName

    while (( SECONDS < deadline )); do
        bootCrons=()
        while read -r cronName; do
            [[ -n "${cronName}" ]] && bootCrons+=("${cronName}")
        done < <(
            oc get dataimportcron -n "${dvNamespace}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
                | grep -E '^(rhel[0-9]+|windows[0-9]*)-image-cron$' || true
        )
        ((${#bootCrons[@]})) && break
        sleep 10
    done

    ((${#bootCrons[@]})) || {
        : "No RHEL/Windows DataImportCrons in ${dvNamespace} after ${appearTimeoutSec}s"
        exit 1
    }

    for cronName in "${bootCrons[@]}"; do
        oc wait DataImportCron -n "${dvNamespace}" "${cronName}" \
            --for=condition=UpToDate --timeout="${waitTimeout}"
    done
    true
}

Cnv__ToggleCommonBootImageImport() {
    typeset status="${1:?}"; (($#)) && shift
    Retry 25 5 oc patch hco kubevirt-hyperconverged -n openshift-cnv \
        --type=merge \
        -p "$(jq -cn --argjson v "${status}" '{"spec":{"enableCommonBootImageImport":$v}}')"

    oc scale deployment hco-operator --replicas 1 -n openshift-cnv

    oc wait hco kubevirt-hyperconverged -n openshift-cnv \
        --for=condition='Available' \
        --timeout='5m'
    true
}

Cnv__WaitNamespacePvcsIdle() {
    typeset ns="${1:?}"; (($#)) && shift
    typeset -i wMax="${1:?}"; (($#)) && shift
    (
        typeset -i wInt=10
        typeset pending
        SECONDS=0
        # Query before entering the loop so the until condition reflects real
        # cluster state on the very first check (pending='' would exit immediately).
        pending="$(oc get pvc -n "${ns}" -o jsonpath-as-json='{.items[*]}' \
            | jq -r '.[] | select(.status.phase | test("Terminating|Pending|Lost")) | .metadata.name' || true)"
        until [[ -z "${pending}" ]]; do
            if (( SECONDS >= wMax )); then
                oc get pvc -n "${ns}" -o wide \
                    > "${ARTIFACT_DIR}/cnv-stuck-pvcs-${ns}.txt" || true
                : "PVCs still not idle in ${ns} after ${wMax}s: ${pending:-<see artifact>}"
                exit 1
            fi
            : "Waiting for PVCs in ${ns} to be idle (${SECONDS}/${wMax}s)"
            sleep "${wInt}"
            pending="$(oc get pvc -n "${ns}" -o jsonpath-as-json='{.items[*]}' \
                | jq -r '.[] | select(.status.phase | test("Terminating|Pending|Lost")) | .metadata.name' || true)"
        done
        true
    )
    true
}

Cnv__ForceDeleteStuckPvcs() {
    typeset ns="${1:?}"; (($#)) && shift
    typeset pvcName
    while read -r pvcName; do
        [[ -n "${pvcName}" ]] || continue
        : "Removing finalizers from stuck PVC ${ns}/${pvcName}"
        oc patch pvc "${pvcName}" -n "${ns}" \
            -p '{"metadata":{"finalizers":null}}' --type=merge || true
    done < <(
        oc get pvc -n "${ns}" -o jsonpath-as-json='{.items[*]}' \
            | jq -r '.[] | select(.metadata.deletionTimestamp != null) | .metadata.name' || true
    )
    true
}

Cnv__WaitBootImagesUpToDate() {
    typeset dvNamespace="openshift-virtualization-os-images"
    typeset -i pvcWaitTimeout="${CNV_DV_NAMESPACE_PVC_WAIT_TIMEOUT}"
    typeset importEnabled=''

    SetDefaultStorageClassForCnv "${CNV_TARGET_STORAGE_CLASS}"

    importEnabled="$(oc get hco kubevirt-hyperconverged -n openshift-cnv \
        -o jsonpath='{.spec.enableCommonBootImageImport}')"
    if [[ "${importEnabled}" != "true" ]]; then
        Cnv__ToggleCommonBootImageImport "true"
    else
        : "enableCommonBootImageImport already true"
    fi

    Cnv__WaitRhelBootImportCronsUpToDate "${dvNamespace}"

    if ! Cnv__WaitNamespacePvcsIdle "${dvNamespace}" "${pvcWaitTimeout}"; then
        Cnv__ForceDeleteStuckPvcs "${dvNamespace}"
        Cnv__WaitNamespacePvcsIdle "${dvNamespace}" "${CNV_DV_NAMESPACE_PVC_RETRY_WAIT_TIMEOUT}"
    fi

    oc get pvc -n "${dvNamespace}"
    true
}

ConfigureOdfVolumeSnapshotClass() {
    typeset -r snapClass='ocs-storagecluster-rbdplugin-snapclass'
    typeset -r snapCtrlNs='openshift-cluster-storage-operator'
    typeset -r snapDeploy='csi-snapshot-controller'

    if ! oc get volumesnapshotclass "${snapClass}" 1>/dev/null; then
        : "VolumeSnapshotClass ${snapClass} not found; skipping default snapshot class setup"
        return 0
    fi

    oc get volumesnapshotclass -o name \
        | xargs -rI{} oc annotate {} snapshot.storage.kubernetes.io/is-default-class- --overwrite
    oc annotate volumesnapshotclass "${snapClass}" \
        snapshot.storage.kubernetes.io/is-default-class=true --overwrite

    if oc -n "${snapCtrlNs}" get deployment "${snapDeploy}" 1>/dev/null; then
        oc -n "${snapCtrlNs}" rollout restart "deployment/${snapDeploy}"
        oc -n "${snapCtrlNs}" rollout status "deployment/${snapDeploy}" --timeout=5m
    fi
    true
}

EnsureCdiStorageProfileRwx() {
    typeset storageClassName="${1:?}"; (($#)) && shift

    if ! oc get storageprofile "${storageClassName}" 1>/dev/null; then
        : "StorageProfile ${storageClassName} not found; skipping RWX patch"
        return 0
    fi

    oc patch storageprofile "${storageClassName}" --type=merge -p \
        "$(jq -cn '{
            "spec": {
                "claimPropertySets": [
                    {"accessModes": ["ReadWriteMany"], "volumeMode": "Block"},
                    {"accessModes": ["ReadWriteOnce"], "volumeMode": "Block"},
                    {"accessModes": ["ReadWriteOnce"], "volumeMode": "Filesystem"}
                ]
            }
        }')"

    : "StorageProfile ${storageClassName} patched — RWX Block is now the first claimPropertySet"
    oc get storageprofile "${storageClassName}" \
        -o jsonpath='{.spec.claimPropertySets}' | jq .
    true
}

WaitOdfCsiHealthy() {
    typeset -r odfNs="openshift-storage"
    typeset -r rbdDeploy="openshift-storage.rbd.csi.ceph.com-ctrlplugin"
    typeset -r rbdNodeDs="openshift-storage.rbd.csi.ceph.com-nodeplugin"
    : "Restarting ODF RBD CSI controller and node plugin to flush stale volume locks"
    oc -n "${odfNs}" rollout restart "deployment/${rbdDeploy}"
    oc -n "${odfNs}" rollout status "deployment/${rbdDeploy}" --timeout=5m
    oc -n "${odfNs}" rollout restart "daemonset/${rbdNodeDs}"
    oc -n "${odfNs}" rollout status "daemonset/${rbdNodeDs}" --timeout=10m
    true
}

# Wait for the ODF StorageCluster and underlying Ceph cluster to be fully healthy
# after an OCP upgrade. The OCP node drain/reboot cycle causes Ceph OSDs to restart
# and PGs to enter recovery/rebalancing state. Performing large writes (e.g. 70 GiB
# Windows DV import) or CSI clone operations while Ceph is still recovering causes
# severe I/O slowdown and DV timeout failures. This function waits for:
#   1. StorageCluster phase = Ready
#   2. CephCluster health = HEALTH_OK or HEALTH_WARN (not ERROR / UNKNOWN)
WaitOdfStorageClusterHealthy() {
    typeset -r odfNs="openshift-storage"
    typeset -r scName="ocs-storagecluster"
    typeset -i waitMaxSec=1800  # 30 min — OSD recovery after full upgrade can take 10–20 min
    typeset -i pollIntervalSec=30

    (
        typeset scPhase=''
        SECONDS=0
        : "Waiting for ODF StorageCluster ${scName} to be Ready (max ${waitMaxSec}s)"
        until [[ "${scPhase}" == "Ready" ]]; do
            scPhase="$(oc get storagecluster "${scName}" -n "${odfNs}" \
                -o jsonpath='{.status.phase}' || true)"
            [[ "${scPhase}" == "Ready" ]] && break
            (( SECONDS >= waitMaxSec )) && {
                oc get storagecluster "${scName}" -n "${odfNs}" -o yaml \
                    > "${ARTIFACT_DIR}/odf-storagecluster-not-ready.yaml" || true
                : "Timed out waiting for StorageCluster ${scName} to be Ready (phase=${scPhase})"
                exit 1
            }
            : "StorageCluster phase=${scPhase:-<empty>}; waiting (${SECONDS}/${waitMaxSec}s)"
            sleep "${pollIntervalSec}"
        done
        : "StorageCluster ${scName} is Ready"

        typeset cephHealth=''
        : "Waiting for CephCluster health to be HEALTH_OK or HEALTH_WARN"
        until [[ "${cephHealth}" == "HEALTH_OK" || "${cephHealth}" == "HEALTH_WARN" ]]; do
            cephHealth="$(oc get cephcluster -n "${odfNs}" \
                -o jsonpath='{.items[0].status.ceph.health}' || true)"
            [[ "${cephHealth}" == "HEALTH_OK" || "${cephHealth}" == "HEALTH_WARN" ]] && break
            (( SECONDS >= waitMaxSec )) && {
                oc get cephcluster -n "${odfNs}" -o yaml \
                    > "${ARTIFACT_DIR}/odf-cephcluster-unhealthy.yaml" || true
                : "Timed out waiting for CephCluster to be HEALTH_OK/WARN (health=${cephHealth})"
                exit 1
            }
            : "CephCluster health=${cephHealth:-<empty>}; waiting (${SECONDS}/${waitMaxSec}s)"
            sleep "${pollIntervalSec}"
        done
        : "CephCluster health=${cephHealth} — ODF storage cluster is ready for I/O"
        true
    )
    true
}

# Restart the HPP operator deployment and CSI DaemonSet to flush any stale
# in-flight volume operation locks that can accumulate after OCP node upgrades
# (drain/reboot cycle). Mirrors WaitOdfCsiHealthy for the HPP storage stack.
# Also force-restarts any stuck hpp-pool-* deployments so that the pods remount
# their ODF-backed PVCs against the freshly restarted CSI node plugin, and then
# waits for all HPP pool deployments to become available before proceeding.
# Guard: no-op when HPP is not installed (not all clusters use HPP storage).
WaitHppCsiHealthy() {
    typeset -r hppNs="openshift-cnv"
    typeset -r hppOperatorDeploy="hostpath-provisioner-operator"
    typeset -r hppCsiDs="hostpath-provisioner-csi"

    if ! oc get deployment "${hppOperatorDeploy}" -n "${hppNs}" 1>/dev/null; then
        : "HPP operator not present in ${hppNs} — skipping WaitHppCsiHealthy"
        return 0
    fi

    : "Restarting HPP operator and CSI DaemonSet to flush stale volume locks"
    oc -n "${hppNs}" rollout restart "deployment/${hppOperatorDeploy}"
    oc -n "${hppNs}" rollout status "deployment/${hppOperatorDeploy}" --timeout=5m
    oc -n "${hppNs}" rollout restart "daemonset/${hppCsiDs}"
    oc -n "${hppNs}" rollout status "daemonset/${hppCsiDs}" --timeout=10m

    # Rollout restart every hpp-pool-* deployment so each pool pod remounts its
    # ODF PVC against the freshly restarted CSI node plugin and clears any Ceph
    # RBD stale locks created by prior OCP upgrade node drain/reboot churn.
    typeset hppPoolDeploy
    while read -r hppPoolDeploy; do
        [[ -z "${hppPoolDeploy}" ]] && continue
        : "Rollout restarting HPP pool deployment ${hppPoolDeploy}"
        oc -n "${hppNs}" rollout restart "${hppPoolDeploy}" || true
    done < <(oc get deployment -n "${hppNs}" -o name | grep '/hpp-pool-' || true)

    # Wait for all hpp-pool-* deployments to have at least one available replica.
    (
        typeset -i waitMaxSec=600
        typeset notReady
        SECONDS=0
        # Select hpp-pool-* deployments where readyReplicas < replicas using jq on the JSON list.
        notReady="$(oc get deployment -n "${hppNs}" -o json \
            | jq -r '.items[] | select(.metadata.name | startswith("hpp-pool-"))
                | select((.status.readyReplicas // 0) < (.spec.replicas // 1))
                | .metadata.name' || true)"
        until [[ -z "${notReady}" ]]; do
            if (( SECONDS >= waitMaxSec )); then
                oc get deployment -n "${hppNs}" -o wide \
                    > "${ARTIFACT_DIR}/hpp-pool-deployments-stuck.txt" 2>&1 || true
                oc get pods -n "${hppNs}" -l 'k8s-app=hostpath-provisioner' -o wide \
                    >> "${ARTIFACT_DIR}/hpp-pool-deployments-stuck.txt" 2>&1 || true
                : "HPP pool deployments not ready after ${waitMaxSec}s: ${notReady}"
                exit 1
            fi
            : "Waiting for HPP pool deployments to be available (${SECONDS}/${waitMaxSec}s): ${notReady}"
            sleep 15
            notReady="$(oc get deployment -n "${hppNs}" -o json \
                | jq -r '.items[] | select(.metadata.name | startswith("hpp-pool-"))
                    | select((.status.readyReplicas // 0) < (.spec.replicas // 1))
                    | .metadata.name' || true)"
        done
        : "All HPP pool deployments are available"
        true
    )
    true
}

# Wait for HCO to report Available before operating on HCO-managed resources.
# The spoke-upgrade-healthcheck only verifies OCP ClusterOperators and nodes —
# it does not wait for CNV/HCO to re-stabilise after the OCP upgrade.
# Required before Cnv__WaitBootImagesUpToDate (DataImportCrons managed by HCO/CDI)
# and SlowDownHcoWorkloadUpdateForUpgradeTest (patches hyperconverged CR directly).
WaitCnvHcoAvailable() {
    typeset -r ns="openshift-cnv"
    typeset -i waitMaxSec=600  # 10 min — HCO reconciliation after OCP upgrade
    typeset -i pollIntervalSec=15
    (
        typeset cond=''
        SECONDS=0
        : "Waiting for HyperConverged kubevirt-hyperconverged Available (max ${waitMaxSec}s)"
        until [[ "${cond}" == "True" ]]; do
            cond="$(oc -n "${ns}" get hyperconverged kubevirt-hyperconverged \
                -o jsonpath='{range .status.conditions[?(@.type=="Available")]}{.status}{end}' \
                || true)"
            [[ "${cond}" == "True" ]] && break
            (( SECONDS >= waitMaxSec )) && {
                printf 'ERROR: HyperConverged not Available after %ds\n' "${waitMaxSec}" >&2
                oc get hyperconverged kubevirt-hyperconverged -n "${ns}" -o yaml \
                    > "${ARTIFACT_DIR}/hco-not-available.yaml" 2>&1 || true
                exit 1
            }
            : "HyperConverged Available=${cond:-<empty>}; waiting (${SECONDS}/${waitMaxSec}s)"
            sleep "${pollIntervalSec}"
        done
        : "HyperConverged Available=True"
        true
    )
    true
}

InstallAndVerifyVirtctl() {
    typeset baseURL
    if ! baseURL="$(oc get ingress.config.openshift.io/cluster -o jsonpath='{.spec.domain}' | tr -d '\n\r')"; then
        exit 1
    fi

    typeset dlURL="https://hyperconverged-cluster-cli-download-openshift-cnv.${baseURL}/amd64/linux/virtctl.tar.gz"
    typeset -a _virtFURL=()
    type -t wget 1>/dev/null && _virtFURL=(wget -q --no-check-certificate -O-) || _virtFURL=(curl -kfsSL)
    if ! "${_virtFURL[@]}" "${dlURL}" | tar -xzf - -C "${binFolder}"; then
        exit 1
    fi

    if [[ ! -x "${binFolder}/virtctl" ]]; then
        typeset virtctlPath
        virtctlPath="$(find "${binFolder}" -name virtctl -type f -executable | head -1)"
        if [[ -n "${virtctlPath}" ]]; then
            mv "${virtctlPath}" "${binFolder}/virtctl"
        fi
    fi

    if ! virtctl version --client; then
        exit 1
    fi
    true
}

# Ensure the subscription's pending install plan targets CNV_TARGET_VERSION before the
# pytest suite runs. In the standard one-hop upgrade case (4.20.z → 4.21.0) OLM has
# already created that plan with Manual approval, and this function returns immediately.
# The loop is retained as a safety net for graphs that require an intermediate step;
# any such intermediate plan is approved and waited on before checking for the target.
PrepareCnvOlmForUpgradeTest() {
    typeset -r targetCsv="kubevirt-hyperconverged-operator.v${CNV_TARGET_VERSION:?}"
    typeset -r ns="openshift-cnv"
    typeset -r subApi="subscription.operators.coreos.com/hco-operatorhub"
    typeset -i maxHops=10
    typeset -i planPollMax=180  # seconds to wait for OLM to create/update a plan
    typeset -i planPollInt=10
    typeset -i csvInstallMax=1800  # 30 min per intermediate CSV install
    typeset -i csvInstallInt=30

    (
        typeset -i hop=0
        typeset subIp='' ipCsv='' ipPhase='' installedCsv=''

        while (( hop < maxHops )); do
            (( ++hop ))

            subIp=''
            SECONDS=0
            until [[ -n "${subIp}" ]]; do
                subIp="$(oc get "${subApi}" -n "${ns}" \
                    -o jsonpath='{.status.installplan.name}' || true)"
                [[ -n "${subIp}" ]] && break
                (( SECONDS >= planPollMax )) && break
                sleep "${planPollInt}"
            done

            if [[ -z "${subIp}" ]]; then
                : "Hop ${hop}: no install plan found after ${planPollMax}s; proceeding to target wait"
                break
            fi

            ipCsv="$(oc get "installplan/${subIp}" -n "${ns}" \
                -o jsonpath='{.spec.clusterServiceVersionNames[0]}' || true)"

            if [[ "${ipCsv}" == "${targetCsv}" ]]; then
                : "Hop ${hop}: install plan ${subIp} already targets ${targetCsv}"
                break
            fi

            ipPhase="$(oc get "installplan/${subIp}" -n "${ns}" \
                -o jsonpath='{.status.phase}' || true)"
            : "Hop ${hop}: approving intermediate plan ${subIp} (${ipCsv}) phase=${ipPhase}"

            if [[ "${ipPhase}" == "RequiresApproval" ]]; then
                oc patch "installplan/${subIp}" -n "${ns}" --type merge \
                    -p '{"spec":{"approved":true}}'
            fi

            installedCsv=''
            SECONDS=0
            until [[ "${installedCsv}" == "${ipCsv}" ]]; do
                installedCsv="$(oc get "${subApi}" -n "${ns}" \
                    -o jsonpath='{.status.installedCSV}' || true)"
                [[ "${installedCsv}" == "${ipCsv}" ]] && break
                (( SECONDS >= csvInstallMax )) && {
                    oc get subscription.operators.coreos.com,installplan,csv -n "${ns}" -o yaml \
                        > "${ARTIFACT_DIR}/cnv-intermediate-install-wait-failure.yaml" || true
                    : "Timed out waiting for intermediate CSV ${ipCsv} to install (${SECONDS}s)"
                    exit 1
                }
                : "Hop ${hop}: waiting for ${ipCsv} to install (${SECONDS}/${csvInstallMax}s)"
                sleep "${csvInstallInt}"
            done
            : "Hop ${hop}: ${ipCsv} installed; waiting for OLM to resolve next plan"
            sleep 15
            subIp=''
        done

        typeset -i targetWaitMax=600
        SECONDS=0
        subIp=''
        ipCsv=''
        until [[ "${ipCsv}" == "${targetCsv}" ]]; do
            subIp="$(oc get "${subApi}" -n "${ns}" \
                -o jsonpath='{.status.installplan.name}' || true)"
            ipCsv=''
            if [[ -n "${subIp}" ]]; then
                ipCsv="$(oc get "installplan/${subIp}" -n "${ns}" \
                    -o jsonpath='{.spec.clusterServiceVersionNames[0]}' || true)"
            fi
            [[ "${ipCsv}" == "${targetCsv}" ]] && break
            (( SECONDS >= targetWaitMax )) && {
                oc get subscription.operators.coreos.com,installplan,csv -n "${ns}" -o yaml \
                    > "${ARTIFACT_DIR}/cnv-upgrade-installplan-wait-failure.yaml" || true
                : "Timed out waiting for ${targetCsv} install plan (current=${subIp}/${ipCsv})"
                exit 1
            }
            : "Waiting for ${targetCsv} install plan (${SECONDS}/${targetWaitMax}s, current=${subIp}/${ipCsv})"
            sleep 10
        done

        oc get subscription.operators.coreos.com,installplan,csv -n openshift-cnv -o wide \
            > "${ARTIFACT_DIR}/cnv-pre-upgrade-olm-state.txt" || true
        : "CNV OLM ready: hco-operatorhub points to ${targetCsv} plan ${subIp}"
        true
    )
    true
}

# Slow down the HCO workload update controller before the CNV upgrade so that
# VMIs created by the pre-upgrade observability test
# (test_metric_kubevirt_vmi_number_of_outdated_before_upgrade) remain outdated
# long enough for the post-upgrade metric checks to pass.
#
# Two-part problem this solves:
#  1. Default behaviour (~1m interval): the workload updater migrates the VMI
#     within ~30 min of the upgrade, clearing the outdatedLauncherImage label
#     and zeroing the Prometheus metric before tests 16-17 run.
#  2. workloadUpdateMethods: [] (previously tried): the workload updater still
#     labels the VMI (test_outdated_vmis_count passes) but does NOT publish the
#     kubevirt_vmi_number_of_outdated Prometheus metric — that metric is only
#     exported when at least one active workload update method is configured.
#
# Solution: keep LiveMigrate as the update method (so the metric IS published)
# but set batchEvictionInterval to 12 h so the first migration batch starts
# well after the test suite has finished.
SlowDownHcoWorkloadUpdateForUpgradeTest() {
    Retry 25 5 oc patch hco kubevirt-hyperconverged -n openshift-cnv \
        --type=merge \
        -p '{"spec":{"workloadUpdateStrategy":{"workloadUpdateMethods":["LiveMigrate"],"batchEvictionInterval":"12h0m0s","batchEvictionSize":1}}}'
    true
}

# ── main ──────────────────────────────────────────────────────────────────────

typeset binFolder
binFolder="$(mktemp -d /tmp/bin.XXXX)"
export PATH="${binFolder}:${PATH}"

[ -f "${SHARED_DIR}/managed-cluster-kubeconfig" ]
export KUBECONFIG="${SHARED_DIR}/managed-cluster-kubeconfig"

trap '
    (($?)) || exit 0
    oc get storagecluster,cephcluster -n openshift-storage -o yaml \
        > "${ARTIFACT_DIR}/odf-state-on-failure.yaml" 2>&1 || true
    oc get pvc -A -o wide \
        > "${ARTIFACT_DIR}/pvcs-on-failure.txt" 2>&1 || true
    oc get subscription.operators.coreos.com,installplan,csv -n openshift-cnv -o yaml \
        > "${ARTIFACT_DIR}/cnv-olm-state-on-failure.yaml" 2>&1 || true
' EXIT

if [[ -n "${CNV_TARGET_MAJOR_MINOR}" ]]; then
    typeset resolvedCnvVersion
    resolvedCnvVersion="$(ResolveCnvFirstVersion "${CNV_TARGET_MAJOR_MINOR}" "${CNV_CHANNEL}")"
    [[ -n "${resolvedCnvVersion}" ]]
    export CNV_TARGET_VERSION="${resolvedCnvVersion}"
    : "Resolved CNV ${CNV_TARGET_MAJOR_MINOR}.x -> ${CNV_TARGET_VERSION} (first z-stream) from packagemanifest/${CNV_CHANNEL}"
fi

printf '%s\n' "${CNV_TARGET_VERSION}" > "${SHARED_DIR}/cnv-target-version"
: "CNV_TARGET_VERSION=${CNV_TARGET_VERSION} written to ${SHARED_DIR}/cnv-target-version"

oc whoami --show-console
oc get "subscription.operators.coreos.com/hco-operatorhub" -n openshift-cnv

: "CNV upgrade prep on spoke: target ${CNV_TARGET_VERSION} via ${CNV_CHANNEL}"

oc get sc
SetDefaultStorageClassForCnv "${CNV_TARGET_STORAGE_CLASS}"
ConfigureOdfVolumeSnapshotClass
EnsureCdiStorageProfileRwx "${CNV_TARGET_STORAGE_CLASS}"
oc get sc

WaitOdfStorageClusterHealthy
WaitOdfCsiHealthy
WaitHppCsiHealthy
WaitCnvHcoAvailable

printf '%s\n' 'wait_only' > "${ARTIFACT_DIR}/cnv-boot-image-prep-mode.txt"
Cnv__WaitBootImagesUpToDate
Cnv__WaitNamespacePvcsIdle openshift-virtualization-os-images "${CNV_DV_NAMESPACE_PVC_WAIT_TIMEOUT}"

InstallAndVerifyVirtctl

PrepareCnvOlmForUpgradeTest
SlowDownHcoWorkloadUpdateForUpgradeTest

true
