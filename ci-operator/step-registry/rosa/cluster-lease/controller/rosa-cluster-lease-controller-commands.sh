#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

LEASE_NAMESPACE="${LEASE_NAMESPACE:-rosa-cluster-lease}"
LEASE_HOST_KUBECONFIG="/etc/rosa-cluster-lease-manager/kubeconfig"
OCM_LOGIN_ENV="${OCM_LOGIN_ENV:-staging}"
STALE_LEASE_HOURS="${STALE_LEASE_HOURS:-4}"
ERROR_REPLACE_HOURS="${ERROR_REPLACE_HOURS:-1}"
DRY_RUN="${DRY_RUN:-false}"

if [[ ! -f "${LEASE_HOST_KUBECONFIG}" ]]; then
    log "ERROR: Lease host kubeconfig not found at ${LEASE_HOST_KUBECONFIG}"
    exit 1
fi

lease_oc() {
    oc --kubeconfig="${LEASE_HOST_KUBECONFIG}" "$@"
}

dry_run_guard() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "DRY RUN: $*"
        return 0
    fi
    return 1
}

# Log in to OCM
SSO_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id" 2>/dev/null || true)
SSO_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret" 2>/dev/null || true)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token" 2>/dev/null || true)

if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
    log "Logging into OCM ${OCM_LOGIN_ENV} with SSO credentials"
    ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${OCM_TOKEN}" ]]; then
    log "Logging into OCM ${OCM_LOGIN_ENV} with offline token"
    ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
else
    log "ERROR: No OCM credentials found in cluster profile"
    exit 1
fi

CURRENT_OCM_ENV="${OCM_LOGIN_ENV}"

ocm_ensure_env() {
    local target_env="$1"
    if [[ "${CURRENT_OCM_ENV}" == "${target_env}" ]]; then
        return 0
    fi
    if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
        ocm login --url "${target_env}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
    elif [[ -n "${OCM_TOKEN}" ]]; then
        ocm login --url "${target_env}" --token "${OCM_TOKEN}"
    fi
    CURRENT_OCM_ENV="${target_env}"
}

NOW_EPOCH=$(date +%s)
STALE_THRESHOLD=$((STALE_LEASE_HOURS * 3600))
ERROR_THRESHOLD=$((ERROR_REPLACE_HOURS * 3600))
REPORT="${ARTIFACT_DIR}/controller-report.txt"
echo "Lease Controller Report - $(date -u)" > "${REPORT}"
echo "======================================" >> "${REPORT}"

# ---------------------------------------------------------------
# Phase 1: Read desired state
# ---------------------------------------------------------------
log "Phase 1: Reading desired state"

DESIRED_CM=$(lease_oc get configmap rosa-cluster-lease-config -n "${LEASE_NAMESPACE}" -o json 2>/dev/null || echo "")
if [[ -z "${DESIRED_CM}" ]]; then
    log "ERROR: rosa-cluster-lease-config ConfigMap not found in ${LEASE_NAMESPACE}"
    log "Create it with a 'desired-clusters' data key containing YAML cluster definitions"
    exit 1
fi

if ! DESIRED_YAML=$(echo "${DESIRED_CM}" | jq -er '.data["desired-clusters"]'); then
    log "ERROR: desired-clusters key missing from rosa-cluster-lease-config"
    exit 1
fi

if ! DESIRED_NAMES=$(echo "${DESIRED_YAML}" | python3 -c "
import sys, yaml, json
clusters = yaml.safe_load(sys.stdin.read()) or []
for c in clusters:
    print(json.dumps(c))
"); then
    log "ERROR: Failed to parse desired-clusters YAML"
    exit 1
fi

DESIRED_COUNT=$(echo "${DESIRED_NAMES}" | grep -c '{' || echo "0")
if [[ "${DESIRED_COUNT}" -eq 0 ]]; then
    log "ERROR: desired-clusters is empty, refusing to reconcile (would decommission all clusters)"
    exit 1
fi
log "Desired clusters: ${DESIRED_COUNT}"

# ---------------------------------------------------------------
# Phase 2: Read actual state
# ---------------------------------------------------------------
log "Phase 2: Reading actual state"

ACTUAL_CMS=$(lease_oc get configmap -n "${LEASE_NAMESPACE}" -l "rosa-cluster-lease/managed=true" -o json 2>/dev/null || echo '{"items":[]}')
ACTUAL_COUNT=$(echo "${ACTUAL_CMS}" | jq '.items | length')
log "Actual clusters: ${ACTUAL_COUNT}"

# ---------------------------------------------------------------
# Phase 3: Provision missing clusters
# ---------------------------------------------------------------
log "Phase 3: Checking for missing clusters"

echo "${DESIRED_NAMES}" | while IFS= read -r cluster_json; do
    [[ -z "${cluster_json}" ]] && continue

    NAME=$(echo "${cluster_json}" | jq -r '.name')
    ENV=$(echo "${cluster_json}" | jq -r '.env // "staging"')
    REGION=$(echo "${cluster_json}" | jq -r '.region // "us-east-1"')
    TYPE=$(echo "${cluster_json}" | jq -r '.type // "classic-sts"')
    VERSION=$(echo "${cluster_json}" | jq -r '.version // "4.22"')
    CHANNEL=$(echo "${cluster_json}" | jq -r '.["channel-group"] // "stable"')
    COMPUTE_NODES=$(echo "${cluster_json}" | jq -r '.["compute-nodes"] // "2"')
    MACHINE_TYPE=$(echo "${cluster_json}" | jq -r '.["machine-type"] // "m5.xlarge"')

    # Check if cluster already exists
    EXISTING=$(echo "${ACTUAL_CMS}" | jq -r ".items[] | select(.metadata.name == \"${NAME}\") | .metadata.name" 2>/dev/null || true)
    if [[ -n "${EXISTING}" ]]; then
        continue
    fi

    log "PROVISION: ${NAME} (${TYPE}, ${ENV}, ${REGION}, ${VERSION})"
    echo "PROVISION: ${NAME} env=${ENV} region=${REGION} version=${VERSION}" >> "${REPORT}"

    if dry_run_guard "Would provision ${NAME}"; then
        continue
    fi

    # Log in to the right OCM environment for this cluster
    ocm_ensure_env "${ENV}"

    # Resolve latest version
    FULL_VERSION=$(rosa list versions --channel-group "${CHANNEL}" -o json 2>/dev/null \
        | jq -r '.[] | select(.enabled == true) | select(.raw_id | startswith("'"${VERSION}"'")) | .raw_id' \
        | sort -V | tail -n1)

    if [[ -z "${FULL_VERSION}" ]]; then
        log "WARNING: No available version matching ${VERSION} in ${CHANNEL}. Skipping ${NAME}."
        continue
    fi

    log "Resolved version: ${FULL_VERSION}"

    # Read shared OIDC config ID from the config ConfigMap
    OIDC_CONFIG_ID=$(echo "${DESIRED_CM}" | jq -r '.data["oidc-config-id"] // empty')
    if [[ -z "${OIDC_CONFIG_ID}" ]]; then
        log "WARNING: No oidc-config-id in lease config. Skipping ${NAME}."
        continue
    fi

    # Read account role prefix
    ROLE_PREFIX=$(echo "${DESIRED_CM}" | jq -r '.data["account-role-prefix"] // "rosa-lease"')

    # Get AWS account ID for role ARNs
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
    if [[ -z "${AWS_ACCOUNT_ID}" ]]; then
        log "WARNING: Cannot determine AWS account ID. Skipping ${NAME}."
        continue
    fi

    rosa create cluster -y \
        --cluster-name "${NAME}" \
        --sts \
        --mode auto \
        --region "${REGION}" \
        --version "${FULL_VERSION}" \
        --channel-group "${CHANNEL}" \
        --compute-nodes "${COMPUTE_NODES}" \
        --compute-machine-type "${MACHINE_TYPE}" \
        --role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_PREFIX}-Installer-Role" \
        --support-role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_PREFIX}-Support-Role" \
        --worker-iam-role "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_PREFIX}-Worker-Role" \
        --controlplane-iam-role "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_PREFIX}-ControlPlane-Role" \
        --oidc-config-id "${OIDC_CONFIG_ID}" \
        --operator-roles-prefix "${NAME}" \
        --tags "rosa-cluster-lease:true,lease-managed:true" \
        || { log "ERROR: Failed to create cluster ${NAME}"; continue; }

    # Get cluster ID immediately after create
    CLUSTER_JSON_EARLY=$(rosa describe cluster -c "${NAME}" -o json 2>/dev/null || true)
    CLUSTER_ID=$(echo "${CLUSTER_JSON_EARLY}" | jq -r '.id // empty')

    if [[ -n "${CLUSTER_ID}" ]]; then
        # Register early so the controller can track it
        cat <<EARLY_EOF | lease_oc apply -n "${LEASE_NAMESPACE}" -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${NAME}
  namespace: ${LEASE_NAMESPACE}
  labels:
    rosa-cluster-lease/managed: "true"
    rosa-cluster-lease/type: ${TYPE}
    rosa-cluster-lease/env: ${ENV}
    rosa-cluster-lease/region: ${REGION}
    rosa-cluster-lease/version: "${VERSION}"
    rosa-cluster-lease/status: provisioning
  annotations:
    rosa-cluster-lease/registered-at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
data:
  cluster-id: "${CLUSTER_ID}"
  cluster-name: "${NAME}"
  region: "${REGION}"
  ocm-env: "${ENV}"
EARLY_EOF
    fi

    # Wait for cluster to be ready (up to 60 min)
    log "Waiting for ${NAME} to be ready..."
    for attempt in $(seq 1 60); do
        STATE=$(rosa describe cluster -c "${NAME}" -o json 2>/dev/null | jq -r '.state // "unknown"')
        if [[ "${STATE}" == "ready" ]]; then
            break
        fi
        if [[ "${STATE}" == "error" ]]; then
            log "ERROR: Cluster ${NAME} entered error state during provisioning"
            break
        fi
        log "  ${NAME}: state=${STATE} (attempt ${attempt}/60)"
        sleep 60
    done

    if [[ "${STATE}" != "ready" ]]; then
        log "WARNING: ${NAME} not ready after 60 min (state: ${STATE}). Will retry next reconcile."
        continue
    fi

    # Get cluster details
    CLUSTER_JSON=$(rosa describe cluster -c "${NAME}" -o json 2>/dev/null)
    CLUSTER_ID=$(echo "${CLUSTER_JSON}" | jq -r '.id')
    API_URL=$(echo "${CLUSTER_JSON}" | jq -r '.api.url')
    ACTUAL_VERSION=$(echo "${CLUSTER_JSON}" | jq -r '.openshift_version')
    VERSION_LABEL=$(echo "${ACTUAL_VERSION}" | cut -d. -f1,2)

    # Update the early-registered ConfigMap to available with full details
    lease_oc patch configmap "${NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
        "metadata": {
            "labels": { "rosa-cluster-lease/version": "'"${VERSION_LABEL}"'", "rosa-cluster-lease/status": "available" },
            "annotations": {
                "rosa-cluster-lease/holder": "",
                "rosa-cluster-lease/build-id": "",
                "rosa-cluster-lease/acquired-at": "",
                "rosa-cluster-lease/released-at": ""
            }
        },
        "data": {
            "cluster-id": "'"${CLUSTER_ID}"'",
            "api-url": "'"${API_URL}"'",
            "version": "'"${ACTUAL_VERSION}"'"
        }
    }' || true

    log "Registered ${NAME} (${CLUSTER_ID}) in lease inventory"
done

# ---------------------------------------------------------------
# Phase 4: Health check existing clusters
# ---------------------------------------------------------------
log "Phase 4: Health checking existing clusters"

# Re-read actual state (may have changed from provisioning)
ACTUAL_CMS=$(lease_oc get configmap -n "${LEASE_NAMESPACE}" -l "rosa-cluster-lease/managed=true" -o json 2>/dev/null || echo '{"items":[]}')
ACTUAL_COUNT=$(echo "${ACTUAL_CMS}" | jq '.items | length')

HEALTHY=0
UNHEALTHY=0
RECOVERED=0

for i in $(seq 0 $((ACTUAL_COUNT - 1))); do
    CM=$(echo "${ACTUAL_CMS}" | jq ".items[${i}]")
    CM_NAME=$(echo "${CM}" | jq -r '.metadata.name')
    CLUSTER_ID=$(echo "${CM}" | jq -r '.data["cluster-id"]')
    STATUS=$(echo "${CM}" | jq -r '.metadata.labels["rosa-cluster-lease/status"]')
    HOLDER=$(echo "${CM}" | jq -r '.metadata.annotations["rosa-cluster-lease/holder"] // ""')
    ACQUIRED_AT=$(echo "${CM}" | jq -r '.metadata.annotations["rosa-cluster-lease/acquired-at"] // ""')

    # Stale lease recovery
    if [[ "${STATUS}" == "in-use" && -n "${ACQUIRED_AT}" ]]; then
        ACQUIRED_EPOCH=$(date -d "${ACQUIRED_AT}" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "${ACQUIRED_AT}" +%s 2>/dev/null || echo "0")
        LEASE_AGE=$(( NOW_EPOCH - ACQUIRED_EPOCH ))

        if [[ ${LEASE_AGE} -gt ${STALE_THRESHOLD} ]]; then
            LEASE_HOURS=$(( LEASE_AGE / 3600 ))
            log "STALE LEASE: ${CM_NAME} held by ${HOLDER} for ${LEASE_HOURS}h"

            if ! dry_run_guard "Would release stale lease on ${CM_NAME}"; then
                lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
                    "metadata": {
                        "labels": { "rosa-cluster-lease/status": "available" },
                        "annotations": {
                            "rosa-cluster-lease/holder": "",
                            "rosa-cluster-lease/build-id": "",
                            "rosa-cluster-lease/released-at": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'",
                            "rosa-cluster-lease/recovered-by": "controller"
                        }
                    }
                }' || true
            fi
            RECOVERED=$((RECOVERED + 1))
            echo "RECOVERED: ${CM_NAME} (stale ${LEASE_HOURS}h)" >> "${REPORT}"
            continue
        fi
        HEALTHY=$((HEALTHY + 1))
        continue
    fi

    # Skip health checks for in-use clusters
    if [[ "${STATUS}" == "in-use" ]]; then
        HEALTHY=$((HEALTHY + 1))
        continue
    fi

    # Check if maintenance (upgrade) has completed
    if [[ "${STATUS}" == "maintenance" ]]; then
        UPGRADE_TARGET=$(echo "${CM}" | jq -r '.metadata.annotations["rosa-cluster-lease/upgrade-target"] // ""')
        CLUSTER_OCM_ENV=$(echo "${CM}" | jq -r '.data["ocm-env"] // "staging"')
        ocm_ensure_env "${CLUSTER_OCM_ENV}"
        OCM_STATUS=$(ocm describe cluster "${CLUSTER_ID}" --json 2>/dev/null | jq -r '.status.state // "unknown"' 2>/dev/null || echo "unknown")
        CURRENT_VERSION=$(ocm describe cluster "${CLUSTER_ID}" --json 2>/dev/null | jq -r '.openshift_version // ""' 2>/dev/null || true)

        if [[ "${OCM_STATUS}" == "ready" && -n "${UPGRADE_TARGET}" && "${CURRENT_VERSION}" == "${UPGRADE_TARGET}" ]]; then
            log "UPGRADE COMPLETE: ${CM_NAME} upgraded to ${CURRENT_VERSION}"
            VERSION_LABEL=$(echo "${CURRENT_VERSION}" | cut -d. -f1,2)
            if ! dry_run_guard "Would restore ${CM_NAME} to available"; then
                lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
                    "metadata": {
                        "labels": { "rosa-cluster-lease/status": "available", "rosa-cluster-lease/version": "'"${VERSION_LABEL}"'" },
                        "annotations": { "rosa-cluster-lease/upgrade-target": "" }
                    },
                    "data": { "version": "'"${CURRENT_VERSION}"'" }
                }' || true
            fi
            echo "UPGRADE COMPLETE: ${CM_NAME} -> ${CURRENT_VERSION}" >> "${REPORT}"
        fi
        HEALTHY=$((HEALTHY + 1))
        continue
    fi

    # Check OCM cluster status
    CLUSTER_OCM_ENV=$(echo "${CM}" | jq -r '.data["ocm-env"] // "staging"')
    ocm_ensure_env "${CLUSTER_OCM_ENV}"

    OCM_STATUS=$(ocm describe cluster "${CLUSTER_ID}" --json 2>/dev/null | jq -r '.status.state // "unknown"' 2>/dev/null || echo "unreachable")

    if [[ "${OCM_STATUS}" != "ready" ]]; then
        log "UNHEALTHY: ${CM_NAME} OCM status is ${OCM_STATUS}"
        if [[ "${STATUS}" != "error" ]] && ! dry_run_guard "Would mark ${CM_NAME} as error"; then
            lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
                "metadata": {
                    "labels": { "rosa-cluster-lease/status": "error" },
                    "annotations": { "rosa-cluster-lease/error-reason": "OCM status: '"${OCM_STATUS}"'", "rosa-cluster-lease/error-at": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'" }
                }
            }' || true
        fi
        UNHEALTHY=$((UNHEALTHY + 1))
        echo "UNHEALTHY: ${CM_NAME} (OCM: ${OCM_STATUS})" >> "${REPORT}"
        continue
    fi

    # Restore clusters that recovered from error
    if [[ "${STATUS}" == "error" ]]; then
        log "RESTORED: ${CM_NAME} is healthy again"
        if ! dry_run_guard "Would restore ${CM_NAME} to available"; then
            lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
                "metadata": {
                    "labels": { "rosa-cluster-lease/status": "available" },
                    "annotations": { "rosa-cluster-lease/error-reason": "", "rosa-cluster-lease/error-at": "" }
                }
            }' || true
        fi
        echo "RESTORED: ${CM_NAME}" >> "${REPORT}"
    fi

    HEALTHY=$((HEALTHY + 1))
done

# ---------------------------------------------------------------
# Phase 5: Replace unhealthy clusters
# ---------------------------------------------------------------
log "Phase 5: Checking for clusters to replace"

ACTUAL_CMS=$(lease_oc get configmap -n "${LEASE_NAMESPACE}" -l "rosa-cluster-lease/managed=true,rosa-cluster-lease/status=error" -o json 2>/dev/null || echo '{"items":[]}')
ERROR_COUNT=$(echo "${ACTUAL_CMS}" | jq '.items | length')

for i in $(seq 0 $((ERROR_COUNT - 1))); do
    CM=$(echo "${ACTUAL_CMS}" | jq ".items[${i}]")
    CM_NAME=$(echo "${CM}" | jq -r '.metadata.name')
    CLUSTER_ID=$(echo "${CM}" | jq -r '.data["cluster-id"]')
    ERROR_AT=$(echo "${CM}" | jq -r '.metadata.annotations["rosa-cluster-lease/error-at"] // ""')

    if [[ -z "${ERROR_AT}" ]]; then
        continue
    fi

    ERROR_EPOCH=$(date -d "${ERROR_AT}" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "${ERROR_AT}" +%s 2>/dev/null || echo "0")
    ERROR_AGE=$(( NOW_EPOCH - ERROR_EPOCH ))

    if [[ ${ERROR_AGE} -lt ${ERROR_THRESHOLD} ]]; then
        log "${CM_NAME}: in error for $((ERROR_AGE / 60))m, threshold is $((ERROR_THRESHOLD / 60))m. Waiting."
        continue
    fi

    log "REPLACE: ${CM_NAME} has been in error for $((ERROR_AGE / 3600))h, deleting"
    echo "REPLACE: ${CM_NAME} (error for $((ERROR_AGE / 3600))h)" >> "${REPORT}"

    if dry_run_guard "Would delete and replace ${CM_NAME}"; then
        continue
    fi

    # Delete the ROSA cluster
    CLUSTER_OCM_ENV=$(echo "${CM}" | jq -r '.data["ocm-env"] // "staging"')
    ocm_ensure_env "${CLUSTER_OCM_ENV}"

    rosa delete cluster -c "${CLUSTER_ID}" -y 2>/dev/null || true

    # Clean up operator roles and OIDC provider (best effort)
    rosa delete operator-roles -c "${CLUSTER_ID}" -y --mode auto 2>/dev/null || true
    rosa delete oidc-provider -c "${CLUSTER_ID}" -y --mode auto 2>/dev/null || true

    # Remove the ConfigMap (next reconcile will provision a replacement)
    lease_oc delete configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" || true
    log "Deleted ${CM_NAME}. Replacement will be provisioned on next reconcile."
done

# ---------------------------------------------------------------
# Phase 6: Version upgrades
# ---------------------------------------------------------------
log "Phase 6: Checking for version upgrades"

echo "${DESIRED_NAMES}" | while IFS= read -r cluster_json; do
    [[ -z "${cluster_json}" ]] && continue

    NAME=$(echo "${cluster_json}" | jq -r '.name')
    DESIRED_VERSION=$(echo "${cluster_json}" | jq -r '.version // ""')
    CHANNEL=$(echo "${cluster_json}" | jq -r '.["channel-group"] // "stable"')

    [[ -z "${DESIRED_VERSION}" ]] && continue

    # Get actual cluster info
    ACTUAL_CM=$(lease_oc get configmap "${NAME}" -n "${LEASE_NAMESPACE}" -o json 2>/dev/null || echo "")
    [[ -z "${ACTUAL_CM}" ]] && continue

    ACTUAL_VERSION=$(echo "${ACTUAL_CM}" | jq -r '.data.version // ""')
    STATUS=$(echo "${ACTUAL_CM}" | jq -r '.metadata.labels["rosa-cluster-lease/status"]')
    CLUSTER_ID=$(echo "${ACTUAL_CM}" | jq -r '.data["cluster-id"]')

    [[ -z "${ACTUAL_VERSION}" ]] && continue

    # Only upgrade available clusters
    if [[ "${STATUS}" != "available" ]]; then
        continue
    fi

    # Check if actual version is older than desired
    ACTUAL_MINOR=$(echo "${ACTUAL_VERSION}" | cut -d. -f1,2)
    if [[ "${ACTUAL_MINOR}" == "${DESIRED_VERSION}" ]]; then
        continue
    fi

    # Resolve target version
    CLUSTER_OCM_ENV=$(echo "${ACTUAL_CM}" | jq -r '.data["ocm-env"] // "staging"')
    ocm_ensure_env "${CLUSTER_OCM_ENV}"

    TARGET_VERSION=$(rosa list upgrades -c "${CLUSTER_ID}" -o json 2>/dev/null \
        | jq -r --arg desired "${DESIRED_VERSION}" \
          '.[] | select(.version | startswith($desired)) | .version' 2>/dev/null \
        | sort -V | tail -n1 || true)

    if [[ -z "${TARGET_VERSION}" ]]; then
        continue
    fi

    log "UPGRADE: ${NAME} from ${ACTUAL_VERSION} to ${TARGET_VERSION}"
    echo "UPGRADE: ${NAME} ${ACTUAL_VERSION} -> ${TARGET_VERSION}" >> "${REPORT}"

    if dry_run_guard "Would upgrade ${NAME} to ${TARGET_VERSION}"; then
        continue
    fi

    # Mark as maintenance during upgrade
    lease_oc patch configmap "${NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
        "metadata": {
            "labels": { "rosa-cluster-lease/status": "maintenance" },
            "annotations": { "rosa-cluster-lease/upgrade-target": "'"${TARGET_VERSION}"'" }
        }
    }' || true

    rosa upgrade cluster -c "${CLUSTER_ID}" \
        --version "${TARGET_VERSION}" \
        --schedule-date "$(date -u +%Y-%m-%d)" \
        --schedule-time "$(date -u +%H:%M)" \
        -y 2>/dev/null || {
            log "WARNING: Failed to schedule upgrade for ${NAME}"
            lease_oc patch configmap "${NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
                "metadata": { "labels": { "rosa-cluster-lease/status": "available" } }
            }' || true
        }
done

# ---------------------------------------------------------------
# Phase 7: Decommission unwanted clusters
# ---------------------------------------------------------------
log "Phase 7: Checking for clusters to decommission"

ACTUAL_CMS=$(lease_oc get configmap -n "${LEASE_NAMESPACE}" -l "rosa-cluster-lease/managed=true" -o json 2>/dev/null || echo '{"items":[]}')
ACTUAL_COUNT=$(echo "${ACTUAL_CMS}" | jq '.items | length')

for i in $(seq 0 $((ACTUAL_COUNT - 1))); do
    CM_NAME=$(echo "${ACTUAL_CMS}" | jq -r ".items[${i}].metadata.name")
    STATUS=$(echo "${ACTUAL_CMS}" | jq -r ".items[${i}].metadata.labels[\"rosa-cluster-lease/status\"]")

    # Check if this cluster is still desired
    IS_DESIRED=$(echo "${DESIRED_NAMES}" | jq -r "select(.name == \"${CM_NAME}\") | .name" 2>/dev/null || true)
    if [[ -n "${IS_DESIRED}" ]]; then
        continue
    fi

    # Only decommission available clusters (wait for in-use to finish)
    if [[ "${STATUS}" != "available" && "${STATUS}" != "error" ]]; then
        log "${CM_NAME}: not in desired state but status is ${STATUS}, waiting"
        continue
    fi

    CLUSTER_ID=$(echo "${ACTUAL_CMS}" | jq -r ".items[${i}].data[\"cluster-id\"]")
    log "DECOMMISSION: ${CM_NAME} (${CLUSTER_ID}) no longer in desired state"
    echo "DECOMMISSION: ${CM_NAME}" >> "${REPORT}"

    if dry_run_guard "Would decommission ${CM_NAME}"; then
        continue
    fi

    CLUSTER_OCM_ENV=$(echo "${ACTUAL_CMS}" | jq -r ".items[${i}].data[\"ocm-env\"] // \"staging\"")
    ocm_ensure_env "${CLUSTER_OCM_ENV}"

    rosa delete cluster -c "${CLUSTER_ID}" -y 2>/dev/null || true
    rosa delete operator-roles -c "${CLUSTER_ID}" -y --mode auto 2>/dev/null || true
    rosa delete oidc-provider -c "${CLUSTER_ID}" -y --mode auto 2>/dev/null || true
    lease_oc delete configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" || true
    log "Decommissioned ${CM_NAME}"
done

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
echo "" >> "${REPORT}"
echo "Summary: ${HEALTHY} healthy, ${UNHEALTHY} unhealthy, ${RECOVERED} recovered" >> "${REPORT}"

log "Controller reconcile complete"
cat "${REPORT}"
