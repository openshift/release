#!/bin/bash

set -o nounset
set -o pipefail

echo "************ osac-project-gather: collecting OSAC pod logs ************"

REMOTE_ARTIFACT_DIR="/tmp/osac-artifacts"

timeout -s 9 10m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -s "${E2E_NAMESPACE}" "${REMOTE_ARTIFACT_DIR}" <<'REMOTE_EOF'
set -o nounset
set -o pipefail

E2E_NAMESPACE="$1"
ARTIFACT_DIR="$2"

KUBECONFIG=$(find "${KUBECONFIG}" -type f -print -quit 2>/dev/null)
if [[ -z "${KUBECONFIG}" ]]; then
    echo "No kubeconfig found, skipping log collection"
    exit 0
fi

mkdir -p "${ARTIFACT_DIR}"

# Usage: gather_namespace_logs <namespace> <output_dir> [tail_lines]
gather_namespace_logs() {
    local ns="$1" outdir="$2" tail="${3:-}"
    local tail_flag="" tail_prev_flag=""
    if [[ -n "${tail}" ]]; then
        tail_flag="--tail=${tail}"
        tail_prev_flag="--tail=$((tail / 3))"
    fi
    mkdir -p "${outdir}"
    oc get pods -n "${ns}" -o wide > "${outdir}/pods.txt" 2>&1 || true
    oc get events -n "${ns}" --sort-by=.lastTimestamp > "${outdir}/events.txt" 2>&1 || true
    oc describe pods -n "${ns}" > "${outdir}/pods-describe.txt" 2>&1 || true
    oc get deployments -n "${ns}" -o wide > "${outdir}/deployments.txt" 2>&1 || true
    oc get jobs -n "${ns}" -o wide > "${outdir}/jobs.txt" 2>&1 || true
    oc get statefulsets -n "${ns}" -o wide > "${outdir}/statefulsets.txt" 2>&1 || true
    for pod in $(oc get pods -n "${ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        for container in $(oc get pod "${pod}" -n "${ns}" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null); do
            oc logs "${pod}" -n "${ns}" -c "${container}" ${tail_flag} > "${outdir}/pod-${pod}-${container}.log" 2>&1 || true
            oc logs "${pod}" -n "${ns}" -c "${container}" --previous ${tail_prev_flag} > "${outdir}/pod-${pod}-${container}-previous.log" 2>/dev/null || true
        done
        for container in $(oc get pod "${pod}" -n "${ns}" -o jsonpath='{.spec.initContainers[*].name}' 2>/dev/null); do
            oc logs "${pod}" -n "${ns}" -c "${container}" ${tail_flag} > "${outdir}/pod-${pod}-init-${container}.log" 2>&1 || true
        done
    done
}

echo "Gathering OSAC logs from namespace ${E2E_NAMESPACE}..."
gather_namespace_logs "${E2E_NAMESPACE}" "${ARTIFACT_DIR}"

for ns in keycloak ansible-aap; do
    if oc get namespace "${ns}" &>/dev/null; then
        gather_namespace_logs "${ns}" "${ARTIFACT_DIR}/${ns}"
    fi
done

echo "=== Collecting CNV/virtualization diagnostics ==="
mkdir -p "${ARTIFACT_DIR}/cnv"
oc get hyperconverged -A -o yaml > "${ARTIFACT_DIR}/cnv/hyperconverged.yaml" 2>&1 || true
oc get vms -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/cnv/vms.txt" 2>&1 || true
oc get vmis -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/cnv/vmis.txt" 2>&1 || true
oc get datavolumes -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/cnv/datavolumes.txt" 2>&1 || true
oc get pvc -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/cnv/pvcs.txt" 2>&1 || true
oc get events -n openshift-cnv --sort-by=.lastTimestamp > "${ARTIFACT_DIR}/cnv/events-openshift-cnv.txt" 2>&1 || true

# VMs with networkAttachments live in subnet namespaces, not E2E_NAMESPACE.
# Gather VM/DataVolume diagnostics from every namespace referenced by compute instances.
VM_NAMESPACES=$(oc get computeinstances -n "${E2E_NAMESPACE}" \
    -o jsonpath='{.items[*].status.virtualMachineReference.namespace}' 2>/dev/null | tr ' ' '\n' | sort -u)
for ns in ${VM_NAMESPACES}; do
    [[ -z "${ns}" || "${ns}" == "${E2E_NAMESPACE}" ]] && continue
    echo "  Gathering VM diagnostics from subnet namespace ${ns}..."
    mkdir -p "${ARTIFACT_DIR}/cnv/${ns}"
    oc get vms -n "${ns}" -o wide > "${ARTIFACT_DIR}/cnv/${ns}/vms.txt" 2>&1 || true
    oc get vms -n "${ns}" -o yaml > "${ARTIFACT_DIR}/cnv/${ns}/vms.yaml" 2>&1 || true
    oc get vmis -n "${ns}" -o wide > "${ARTIFACT_DIR}/cnv/${ns}/vmis.txt" 2>&1 || true
    oc get datavolumes -n "${ns}" -o wide > "${ARTIFACT_DIR}/cnv/${ns}/datavolumes.txt" 2>&1 || true
    oc get datavolumes -n "${ns}" -o yaml > "${ARTIFACT_DIR}/cnv/${ns}/datavolumes.yaml" 2>&1 || true
    oc get pvc -n "${ns}" -o wide > "${ARTIFACT_DIR}/cnv/${ns}/pvcs.txt" 2>&1 || true
    oc get events -n "${ns}" --sort-by=.lastTimestamp > "${ARTIFACT_DIR}/cnv/${ns}/events.txt" 2>&1 || true
    oc get networkpolicies -n "${ns}" -o yaml > "${ARTIFACT_DIR}/cnv/${ns}/networkpolicies.yaml" 2>&1 || true
done

echo "=== Collecting compute instance status ==="
oc get computeinstances -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/computeinstances.txt" 2>&1 || true
oc get computeinstances -n "${E2E_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/computeinstances.yaml" 2>&1 || true

echo "=== Collecting networking status ==="
oc get virtualnetworks -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/virtualnetworks.txt" 2>&1 || true
oc get virtualnetworks -n "${E2E_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/virtualnetworks.yaml" 2>&1 || true
oc get subnets -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/subnets.txt" 2>&1 || true
oc get subnets -n "${E2E_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/subnets.yaml" 2>&1 || true
oc get securitygroups -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/securitygroups.txt" 2>&1 || true
oc get clusteruserdefinednetwork -o yaml > "${ARTIFACT_DIR}/clusteruserdefinednetwork.yaml" 2>&1 || true
oc get tenants -n "${E2E_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/tenants.yaml" 2>&1 || true
oc get publicips -n "${E2E_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/publicips.yaml" 2>&1 || true
oc get publicippools -n "${E2E_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/publicippools.yaml" 2>&1 || true
oc get publicipattachments -n "${E2E_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/publicipattachments.yaml" 2>&1 || true

echo "=== Collecting cert-manager status ==="
oc get certificates -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/certificates.txt" 2>&1 || true
oc get certificates -n "${E2E_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/certificates.yaml" 2>&1 || true
oc get routes -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/routes.txt" 2>&1 || true
oc get routes -n keycloak -o wide > "${ARTIFACT_DIR}/routes-keycloak.txt" 2>&1 || true

echo "=== Collecting CaaS/HyperShift diagnostics ==="
mkdir -p "${ARTIFACT_DIR}/caas"
oc get clusterorders -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/caas/clusterorders.txt" 2>&1 || true
oc get clusterorders -n "${E2E_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/caas/clusterorders.yaml" 2>&1 || true
oc get hostedclusters -A -o wide > "${ARTIFACT_DIR}/caas/hostedclusters.txt" 2>&1 || true
oc get hostedclusters -A -o yaml > "${ARTIFACT_DIR}/caas/hostedclusters.yaml" 2>&1 || true
oc get nodepools -A -o wide > "${ARTIFACT_DIR}/caas/nodepools.txt" 2>&1 || true
oc get nodepools -A -o yaml > "${ARTIFACT_DIR}/caas/nodepools.yaml" 2>&1 || true
oc get agents -A -o wide > "${ARTIFACT_DIR}/caas/agents.txt" 2>&1 || true
oc get agents -A -o yaml > "${ARTIFACT_DIR}/caas/agents.yaml" 2>&1 || true
oc get infraenvs -A -o wide > "${ARTIFACT_DIR}/caas/infraenvs.txt" 2>&1 || true
oc get infraenvs -A -o yaml > "${ARTIFACT_DIR}/caas/infraenvs.yaml" 2>&1 || true
oc get agentserviceconfig -o yaml > "${ARTIFACT_DIR}/caas/agentserviceconfig.yaml" 2>&1 || true
oc get multiclusterengine -o yaml > "${ARTIFACT_DIR}/caas/multiclusterengine.yaml" 2>&1 || true
oc get ipaddresspool -A -o yaml > "${ARTIFACT_DIR}/caas/metallb-pools.yaml" 2>&1 || true
oc get l2advertisement -A -o yaml > "${ARTIFACT_DIR}/caas/metallb-l2advertisements.yaml" 2>&1 || true
oc get bgpadvertisement -A -o yaml > "${ARTIFACT_DIR}/caas/metallb-bgpadvertisements.yaml" 2>&1 || true
oc get svc -A --field-selector spec.type=LoadBalancer -o wide > "${ARTIFACT_DIR}/caas/loadbalancer-services.txt" 2>&1 || true

echo "=== Collecting HostedCluster control plane diagnostics ==="
oc get ns -o custom-columns=NAME:.metadata.name,STATUS:.status.phase --no-headers 2>/dev/null \
    | grep "^${E2E_NAMESPACE}-" > "${ARTIFACT_DIR}/caas/cp-namespaces.txt" 2>&1 || true
for ns in $(oc get ns -o name 2>/dev/null | grep "^namespace/${E2E_NAMESPACE}-" | sed 's|namespace/||'); do
    oc get ns "${ns}" -o yaml
done > "${ARTIFACT_DIR}/caas/cp-namespaces-detail.yaml" 2>&1 || true
oc get hostedcontrolplane -A -o yaml > "${ARTIFACT_DIR}/caas/hostedcontrolplanes.yaml" 2>&1 || true

# Cluster-wide CAPI resources
oc get cluster.cluster.x-k8s.io -A -o yaml > "${ARTIFACT_DIR}/caas/capi-clusters.yaml" 2>&1 || true
oc get agentclusters.capi-provider.agent-install.openshift.io -A -o yaml > "${ARTIFACT_DIR}/caas/agentclusters.yaml" 2>&1 || true
oc get machines.cluster.x-k8s.io -A -o yaml > "${ARTIFACT_DIR}/caas/capi-machines.yaml" 2>&1 || true
oc get machinesets.cluster.x-k8s.io -A -o yaml > "${ARTIFACT_DIR}/caas/capi-machinesets.yaml" 2>&1 || true
oc get agentmachines.capi-provider.agent-install.openshift.io -A -o yaml > "${ARTIFACT_DIR}/caas/agentmachines.yaml" 2>&1 || true

# Dump ALL resources with finalizers in CP namespaces (catch anything stuck)
for ns in $(oc get ns -o name 2>/dev/null | grep "^namespace/${E2E_NAMESPACE}-" | sed 's|namespace/||'); do
    echo "  Control plane namespace: ${ns}"
    cpdir="${ARTIFACT_DIR}/caas/cp-${ns}"
    gather_namespace_logs "${ns}" "${cpdir}" 3000
    oc get svc -n "${ns}" -o wide > "${cpdir}/svc.txt" 2>&1 || true
    oc get svc -n "${ns}" -o yaml > "${cpdir}/svc.yaml" 2>&1 || true

    # All resources with finalizers (finds anything stuck)
    oc api-resources --verbs=list --namespaced -o name 2>/dev/null | while read resource; do
        oc get "${resource}" -n "${ns}" -o custom-columns=KIND:.kind,NAME:.metadata.name,DELETION:.metadata.deletionTimestamp,FINALIZERS:.metadata.finalizers --no-headers 2>/dev/null \
            | grep -v '<none>$'
    done > "${cpdir}/resources-with-finalizers.txt" 2>&1 || true
done

echo "=== Collecting HyperShift operator diagnostics ==="
HYPERSHIFT_NS=$(oc get deployment -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name --no-headers 2>/dev/null \
    | grep -i "hypershift.*operator" | head -1 | awk '{print $1}')
if [[ -n "${HYPERSHIFT_NS}" ]]; then
    oc get deployments -n "${HYPERSHIFT_NS}" -o wide > "${ARTIFACT_DIR}/caas/hypershift-deployments.txt" 2>&1 || true
    for pod in $(oc get pods -n "${HYPERSHIFT_NS}" -l app=operator -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        oc logs -n "${HYPERSHIFT_NS}" "${pod}" -c operator --tail=10000 \
            > "${ARTIFACT_DIR}/caas/hypershift-${pod}.log" 2>&1 || true
        oc logs -n "${HYPERSHIFT_NS}" "${pod}" -c operator --previous --tail=5000 \
            > "${ARTIFACT_DIR}/caas/hypershift-${pod}-previous.log" 2>/dev/null || true
    done
    oc get pods -n "${HYPERSHIFT_NS}" -o wide > "${ARTIFACT_DIR}/caas/hypershift-pods.txt" 2>&1 || true
    oc describe pods -n "${HYPERSHIFT_NS}" > "${ARTIFACT_DIR}/caas/hypershift-pods-describe.txt" 2>&1 || true
    oc get events -n "${HYPERSHIFT_NS}" --sort-by=.lastTimestamp > "${ARTIFACT_DIR}/caas/hypershift-events.txt" 2>&1 || true
fi

echo "=== Collecting storage diagnostics (LVMS/topolvm) ==="
mkdir -p "${ARTIFACT_DIR}/storage"
oc get pv -o wide > "${ARTIFACT_DIR}/storage/pvs.txt" 2>&1 || true
oc get pv -o yaml > "${ARTIFACT_DIR}/storage/pvs.yaml" 2>&1 || true
oc get pvc -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/storage/pvcs.txt" 2>&1 || true
oc get pvc -n "${E2E_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/storage/pvcs.yaml" 2>&1 || true
oc get sc -o yaml > "${ARTIFACT_DIR}/storage/storageclasses.yaml" 2>&1 || true
oc get logicalvolumes.topolvm.io -o yaml > "${ARTIFACT_DIR}/storage/topolvm-logicalvolumes.yaml" 2>&1 || true
oc get lvmclusters -n openshift-storage -o yaml > "${ARTIFACT_DIR}/storage/lvmclusters.yaml" 2>&1 || true
oc get lvmvolumegroups -n openshift-storage -o yaml > "${ARTIFACT_DIR}/storage/lvmvolumegroups.yaml" 2>&1 || true
oc get events -n openshift-storage --sort-by=.lastTimestamp > "${ARTIFACT_DIR}/storage/events-openshift-storage.txt" 2>&1 || true
for pod in $(oc get pods -n openshift-storage -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    oc logs "${pod}" -n openshift-storage --tail=2000 > "${ARTIFACT_DIR}/storage/pod-${pod}.log" 2>&1 || true
done
oc get pods -n openshift-storage -o wide > "${ARTIFACT_DIR}/storage/pods-openshift-storage.txt" 2>&1 || true
oc describe pv > "${ARTIFACT_DIR}/storage/pvs-describe.txt" 2>&1 || true

echo "=== Collecting node resource usage ==="
oc adm top node > "${ARTIFACT_DIR}/node-resources.txt" 2>&1 || true
oc adm top pod -n "${E2E_NAMESPACE}" --sort-by=memory > "${ARTIFACT_DIR}/pod-resources.txt" 2>&1 || true
oc get nodes -o wide > "${ARTIFACT_DIR}/nodes.txt" 2>&1 || true
oc describe node > "${ARTIFACT_DIR}/node-describe.txt" 2>&1 || true

echo "=== Collecting cluster operator status ==="
oc get co > "${ARTIFACT_DIR}/clusteroperators.txt" 2>&1 || true
oc get csv -n openshift-cnv -o wide > "${ARTIFACT_DIR}/cnv/csv.txt" 2>&1 || true

echo "=== Collecting AAP operator status ==="
oc get ansibleautomationplatform -n "${E2E_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/aap-status.yaml" 2>&1 || true
oc get automationcontroller -n "${E2E_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/automationcontroller-status.yaml" 2>&1 || true

echo "=== Collecting AAP job stdout ==="
mkdir -p "${ARTIFACT_DIR}/aap-jobs"
AAP_ROUTE=$(oc get route osac-aap -n "${E2E_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null)
AAP_ADMIN_PW=$(oc get secret osac-aap-controller-admin-password -n "${E2E_NAMESPACE}" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)
if [[ -n "${AAP_ROUTE}" && -n "${AAP_ADMIN_PW}" ]]; then
    AAP_AUTH=(-sk -u "admin:${AAP_ADMIN_PW}")
    page=1
    while true; do
        page_file="${ARTIFACT_DIR}/aap-jobs/jobs-page-${page}.json"
        curl "${AAP_AUTH[@]}" \
            "https://${AAP_ROUTE}/api/controller/v2/jobs/?page=${page}&page_size=50&order_by=id" \
            > "${page_file}" 2>&1 || break
        jq -e '.results' "${page_file}" &>/dev/null || break
        for job_id in $(jq -r '.results[]?.id // empty' "${page_file}" 2>/dev/null); do
            status=$(jq -r ".results[] | select(.id == ${job_id}) | .status // \"unknown\"" "${page_file}" 2>/dev/null)
            name=$(jq -r ".results[] | select(.id == ${job_id}) | .name // \"unknown\"" "${page_file}" 2>/dev/null)
            curl "${AAP_AUTH[@]}" \
                "https://${AAP_ROUTE}/api/controller/v2/jobs/${job_id}/stdout/?format=txt" \
                > "${ARTIFACT_DIR}/aap-jobs/job-${job_id}-${status}-${name}.txt" 2>&1 || true
        done
        next=$(jq -r '.next // empty' "${page_file}" 2>/dev/null)
        [[ -z "${next}" || "${next}" == "null" ]] && break
        page=$((page + 1))
    done
    echo "  Captured stdout for $(ls "${ARTIFACT_DIR}/aap-jobs"/job-*.txt 2>/dev/null | wc -l) AAP jobs"
    curl "${AAP_AUTH[@]}" \
        "https://${AAP_ROUTE}/api/controller/v2/project_updates/?page_size=50&order_by=id" \
        > "${ARTIFACT_DIR}/aap-jobs/project-updates.json" 2>&1 || true
    for pu_id in $(jq -r '.results[]?.id // empty' "${ARTIFACT_DIR}/aap-jobs/project-updates.json" 2>/dev/null); do
        status=$(jq -r ".results[] | select(.id == ${pu_id}) | .status // \"unknown\"" \
            "${ARTIFACT_DIR}/aap-jobs/project-updates.json" 2>/dev/null)
        curl "${AAP_AUTH[@]}" \
            "https://${AAP_ROUTE}/api/controller/v2/project_updates/${pu_id}/stdout/?format=txt" \
            > "${ARTIFACT_DIR}/aap-jobs/project-update-${pu_id}-${status}.txt" 2>&1 || true
    done
    echo "  Captured $(ls "${ARTIFACT_DIR}/aap-jobs"/project-update-*.txt 2>/dev/null | wc -l) AAP project updates"

    echo "=== Collecting AAP job events for non-successful jobs ==="
    mkdir -p "${ARTIFACT_DIR}/aap-jobs/events"
    for page_file in "${ARTIFACT_DIR}"/aap-jobs/jobs-page-*.json; do
        [[ -f "${page_file}" ]] || continue
        for job_id in $(jq -r '.results[] | select(.status != "successful" and .status != "canceled") | .id // empty' "${page_file}" 2>/dev/null); do
            curl "${AAP_AUTH[@]}" \
                "https://${AAP_ROUTE}/api/controller/v2/jobs/${job_id}/job_events/?page_size=50&order_by=-counter" \
                2>/dev/null | jq '[.results[]? | {counter, event, task: .event_data.task, task_action: .event_data.task_action, role: .event_data.role, failed: .event_data.failed, res_msg: .event_data.res.msg?, res_reason: .event_data.res.reason?, res_error: .event_data.res.error?}]' \
                > "${ARTIFACT_DIR}/aap-jobs/events/job-${job_id}-events.json" 2>&1 || true
            # Full job detail (result_traceback, job_explanation, extra_vars keys)
            curl "${AAP_AUTH[@]}" \
                "https://${AAP_ROUTE}/api/controller/v2/jobs/${job_id}/" \
                2>/dev/null | jq '{id, name, status, failed, result_traceback, job_explanation, started, finished, elapsed}' \
                > "${ARTIFACT_DIR}/aap-jobs/events/job-${job_id}-detail.json" 2>&1 || true
        done
    done
    echo "  Captured events for $(ls "${ARTIFACT_DIR}/aap-jobs/events"/job-*-events.json 2>/dev/null | wc -l) non-successful AAP jobs"
else
    echo "  AAP route or admin password not found, skipping job stdout capture"
fi

echo "Log collection complete"
REMOTE_EOF

echo "Copying artifacts from remote machine..."
timeout -s 9 10m scp -r -F "${SHARED_DIR}/ssh_config" "ci_machine:${REMOTE_ARTIFACT_DIR}" "${ARTIFACT_DIR}/osac-logs" 2>&1 || true

echo "************ osac-project-gather: done ************"
