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

KUBECONFIG=$(find ${KUBECONFIG} -type f -print -quit 2>/dev/null)
if [[ -z "${KUBECONFIG}" ]]; then
    echo "No kubeconfig found, skipping log collection"
    exit 0
fi

mkdir -p "${ARTIFACT_DIR}"

echo "Gathering OSAC logs from namespace ${E2E_NAMESPACE}..."

oc get pods -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/pods.txt" 2>&1 || true
oc get events -n "${E2E_NAMESPACE}" --sort-by=.lastTimestamp > "${ARTIFACT_DIR}/events.txt" 2>&1 || true
oc describe pods -n "${E2E_NAMESPACE}" > "${ARTIFACT_DIR}/pods-describe.txt" 2>&1 || true
oc get deployments -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/deployments.txt" 2>&1 || true
oc get jobs -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/jobs.txt" 2>&1 || true
oc get statefulsets -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/statefulsets.txt" 2>&1 || true

for pod in $(oc get pods -n "${E2E_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    for container in $(oc get pod "${pod}" -n "${E2E_NAMESPACE}" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null); do
        oc logs "${pod}" -n "${E2E_NAMESPACE}" -c "${container}" > "${ARTIFACT_DIR}/pod-${pod}-${container}.log" 2>&1 || true
        oc logs "${pod}" -n "${E2E_NAMESPACE}" -c "${container}" --previous > "${ARTIFACT_DIR}/pod-${pod}-${container}-previous.log" 2>/dev/null || true
    done
    for container in $(oc get pod "${pod}" -n "${E2E_NAMESPACE}" -o jsonpath='{.spec.initContainers[*].name}' 2>/dev/null); do
        oc logs "${pod}" -n "${E2E_NAMESPACE}" -c "${container}" > "${ARTIFACT_DIR}/pod-${pod}-init-${container}.log" 2>&1 || true
    done
done

for ns in keycloak ansible-aap; do
    if oc get namespace "${ns}" &>/dev/null; then
        mkdir -p "${ARTIFACT_DIR}/${ns}"
        oc get pods -n "${ns}" -o wide > "${ARTIFACT_DIR}/${ns}/pods.txt" 2>&1 || true
        oc get events -n "${ns}" --sort-by=.lastTimestamp > "${ARTIFACT_DIR}/${ns}/events.txt" 2>&1 || true
        oc describe pods -n "${ns}" > "${ARTIFACT_DIR}/${ns}/pods-describe.txt" 2>&1 || true
        oc get deployments -n "${ns}" -o wide > "${ARTIFACT_DIR}/${ns}/deployments.txt" 2>&1 || true
        oc get jobs -n "${ns}" -o wide > "${ARTIFACT_DIR}/${ns}/jobs.txt" 2>&1 || true
        oc get statefulsets -n "${ns}" -o wide > "${ARTIFACT_DIR}/${ns}/statefulsets.txt" 2>&1 || true
        for pod in $(oc get pods -n "${ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
            for container in $(oc get pod "${pod}" -n "${ns}" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null); do
                oc logs "${pod}" -n "${ns}" -c "${container}" > "${ARTIFACT_DIR}/${ns}/pod-${pod}-${container}.log" 2>&1 || true
                oc logs "${pod}" -n "${ns}" -c "${container}" --previous > "${ARTIFACT_DIR}/${ns}/pod-${pod}-${container}-previous.log" 2>/dev/null || true
            done
            for container in $(oc get pod "${pod}" -n "${ns}" -o jsonpath='{.spec.initContainers[*].name}' 2>/dev/null); do
                oc logs "${pod}" -n "${ns}" -c "${container}" > "${ARTIFACT_DIR}/${ns}/pod-${pod}-init-${container}.log" 2>&1 || true
            done
        done
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

echo "=== Collecting cert-manager status ==="
oc get certificates -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/certificates.txt" 2>&1 || true
oc get certificates -n "${E2E_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/certificates.yaml" 2>&1 || true
oc get routes -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/routes.txt" 2>&1 || true
oc get routes -n keycloak -o wide > "${ARTIFACT_DIR}/routes-keycloak.txt" 2>&1 || true

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
else
    echo "  AAP route or admin password not found, skipping job stdout capture"
fi

echo "Log collection complete"
REMOTE_EOF

echo "Copying artifacts from remote machine..."
timeout -s 9 5m scp -r -F "${SHARED_DIR}/ssh_config" "ci_machine:${REMOTE_ARTIFACT_DIR}" "${ARTIFACT_DIR}/osac-logs" 2>&1 || true

echo "************ osac-project-gather: done ************"
