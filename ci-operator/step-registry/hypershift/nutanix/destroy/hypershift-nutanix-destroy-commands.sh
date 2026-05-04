#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ hypershift nutanix destroy command ************"

# Source Nutanix context from IPI workflow
if [[ -f "${SHARED_DIR}/nutanix_context.sh" ]]; then
    echo "Loading Nutanix context from IPI workflow..."
    source "${SHARED_DIR}/nutanix_context.sh"

    # Map IPI workflow variables to our naming convention
    NUTANIX_ENDPOINT="${NUTANIX_HOST}"
    NUTANIX_USER="${NUTANIX_USERNAME}"
    # NUTANIX_PASSWORD is already set from nutanix_context.sh

    echo "Using Nutanix endpoint: ${NUTANIX_ENDPOINT}"
else
    echo "WARNING: nutanix_context.sh not found, using environment variables directly"
    NUTANIX_ENDPOINT="${NUTANIX_ENDPOINT:-}"
    NUTANIX_USER="${NUTANIX_USER:-admin}"
    NUTANIX_PASSWORD="${NUTANIX_PASSWORD:-}"
fi

# Get HostedCluster information
HOSTED_CLUSTER_NS=$(oc get hostedcluster -A -ojsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "")
HOSTED_CLUSTER_NAME=$(oc get hostedcluster -A -ojsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -z "${HOSTED_CLUSTER_NAME}" ]]; then
    echo "No HostedCluster found, skipping hosted cluster cleanup"
else
    echo "Destroying HostedCluster: ${HOSTED_CLUSTER_NAME} in namespace ${HOSTED_CLUSTER_NS}"

    HOSTED_CONTROL_PLANE_NS="${HOSTED_CLUSTER_NS}-${HOSTED_CLUSTER_NAME}"

    # Scale down NodePool to prevent new Agents from being used
    echo "Scaling down NodePool..."
    NODEPOOL_NAME=$(oc get nodepool -n ${HOSTED_CLUSTER_NS} --no-headers 2>/dev/null | head -1 | awk '{print $1}' || echo "")
    if [[ -n "${NODEPOOL_NAME}" ]]; then
        oc scale nodepool ${NODEPOOL_NAME} -n ${HOSTED_CLUSTER_NS} --replicas 0 || true
        sleep 10
    fi

    # Delete HostedCluster (this will trigger cascading deletion)
    echo "Deleting HostedCluster CR..."
    oc delete hostedcluster ${HOSTED_CLUSTER_NAME} -n ${HOSTED_CLUSTER_NS} --wait=false || true

    # Wait a bit for cleanup to start
    sleep 30

    # Delete InfraEnv
    echo "Cleaning up InfraEnv..."
    INFRAENV_NAME="${HOSTED_CLUSTER_NAME}-nutanix"
    oc delete infraenv ${INFRAENV_NAME} -n ${HOSTED_CONTROL_PLANE_NS} --ignore-not-found=true || true

    # Delete Agents
    echo "Cleaning up Agent resources..."
    oc delete agent --all -n ${HOSTED_CONTROL_PLANE_NS} --ignore-not-found=true || true

    # Cleanup Nutanix resources
    if [[ -n "${NUTANIX_ENDPOINT}" ]] && [[ -n "${NUTANIX_PASSWORD}" ]]; then
        echo "Cleaning up Nutanix resources..."

        # Find and delete Agent ISOs
        echo "Searching for Agent ISOs in Nutanix..."
        AGENT_ISOS=$(curl -k -s -X POST \
            -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
            "https://${NUTANIX_ENDPOINT}:9440/api/nutanix/v3/images/list" \
            -H 'Content-Type: application/json' \
            -d '{"kind":"image","filter":"name==agent-worker.*"}' \
            | jq -r '.entities[]?.metadata.uuid // empty' 2>/dev/null || echo "")

        if [[ -n "${AGENT_ISOS}" ]]; then
            for iso_uuid in ${AGENT_ISOS}; do
                echo "Deleting ISO: ${iso_uuid}"
                curl -k -s -X DELETE \
                    -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
                    "https://${NUTANIX_ENDPOINT}:9440/api/nutanix/v3/images/${iso_uuid}" || true
                sleep 2
            done
        else
            echo "No Agent ISOs found to cleanup"
        fi

        # Optionally power off and delete worker VMs
        # This depends on whether VMs were pre-created or dynamically created
        if [[ "${NUTANIX_DELETE_WORKER_VMS:-false}" == "true" ]]; then
            echo "Cleaning up Nutanix worker VMs..."

            # Find VMs by naming pattern
            WORKER_VMS=$(curl -k -s -X POST \
                -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
                "https://${NUTANIX_ENDPOINT}:9440/api/nutanix/v3/vms/list" \
                -H 'Content-Type: application/json' \
                -d "{\"kind\":\"vm\",\"filter\":\"name==${NUTANIX_WORKER_VM_PREFIX:-hypershift-worker}.*\"}" \
                | jq -r '.entities[]?.metadata.uuid // empty' 2>/dev/null || echo "")

            if [[ -n "${WORKER_VMS}" ]]; then
                for vm_uuid in ${WORKER_VMS}; do
                    echo "Powering off and deleting VM: ${vm_uuid}"

                    # Power off
                    curl -k -s -X POST \
                        -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
                        "https://${NUTANIX_ENDPOINT}:9440/api/nutanix/v3/vms/${vm_uuid}/acpi_shutdown" \
                        -H 'Content-Type: application/json' || true

                    sleep 10

                    # Delete
                    curl -k -s -X DELETE \
                        -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
                        "https://${NUTANIX_ENDPOINT}:9440/api/nutanix/v3/vms/${vm_uuid}" || true

                    sleep 2
                done
            else
                echo "No worker VMs found matching pattern: ${NUTANIX_WORKER_VM_PREFIX:-hypershift-worker}.*"
            fi
        else
            echo "Skipping worker VM deletion (NUTANIX_DELETE_WORKER_VMS not set to 'true')"
            echo "Note: Worker VMs may still be running. Clean them up manually if needed."
        fi
    else
        echo "Nutanix credentials not available, skipping Nutanix resource cleanup"
    fi

    # Force delete the namespace if it still exists after some time
    echo "Waiting for namespace cleanup..."
    for i in {1..30}; do
        if ! oc get namespace ${HOSTED_CONTROL_PLANE_NS} 2>/dev/null; then
            echo "Namespace ${HOSTED_CONTROL_PLANE_NS} deleted successfully"
            break
        fi
        echo "Waiting for namespace deletion... ($i/30)"
        sleep 10
    done

    # If namespace still exists, force delete
    if oc get namespace ${HOSTED_CONTROL_PLANE_NS} 2>/dev/null; then
        echo "Force deleting namespace ${HOSTED_CONTROL_PLANE_NS}"
        oc delete namespace ${HOSTED_CONTROL_PLANE_NS} --force --grace-period=0 || true
    fi
fi

echo "Nutanix HyperShift hosted cluster cleanup completed"
