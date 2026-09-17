#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

collect_operator_logs() {
    local ns="${OPERATOR_NAMESPACE:-openshift-${OPERATOR_NAME:-unknown}}"
    if [[ -n "${ARTIFACT_DIR:-}" ]] && oc get namespace "${ns}" &>/dev/null; then
        for deploy in $(oc get deployment -n "${ns}" --no-headers -o custom-columns=':metadata.name' 2>/dev/null || true); do
            oc logs "deployment/${deploy}" -n "${ns}" --all-containers --tail=500 \
                > "${ARTIFACT_DIR}/${deploy}-logs.txt" 2>&1 || true
        done
        oc get events -n "${ns}" --sort-by='.lastTimestamp' \
            > "${ARTIFACT_DIR}/operator-namespace-events.txt" 2>&1 || true
    fi
    # Collect PKO diagnostics for debugging ClusterPackage reconciliation issues
    if [[ -n "${ARTIFACT_DIR:-}" ]]; then
        local pko_ns="openshift-package-operator"
        if oc get namespace "${pko_ns}" &>/dev/null; then
            for deploy in $(oc get deployment -n "${pko_ns}" --no-headers -o custom-columns=':metadata.name' 2>/dev/null || true); do
                oc logs "deployment/${deploy}" -n "${pko_ns}" --all-containers --tail=500 \
                    > "${ARTIFACT_DIR}/pko-${deploy}-logs.txt" 2>&1 || true
            done
            oc get events -n "${pko_ns}" --sort-by='.lastTimestamp' \
                > "${ARTIFACT_DIR}/pko-namespace-events.txt" 2>&1 || true
        fi
        oc get clusterpackage "${CLUSTER_PACKAGE_NAME:-}" -o yaml \
            > "${ARTIFACT_DIR}/clusterpackage-dump.yaml" 2>/dev/null || true
        oc get clusterobjectset -o wide \
            > "${ARTIFACT_DIR}/clusterobjectset-list.txt" 2>/dev/null || true
    fi
}

trap 'collect_operator_logs; CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM EXIT

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

# Use shared kubeconfig from provision step if available
if [[ -n "${SHARED_DIR:-}" && -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

if [[ -z "${OPERATOR_NAME:-}" ]]; then
    log "ERROR: OPERATOR_NAME is required"
    exit 1
fi

if [[ -z "${OPERATOR_PKO_IMAGE:-}" ]]; then
    log "ERROR: OPERATOR_PKO_IMAGE is required"
    exit 1
fi

if [[ -z "${OPERATOR_IMAGE:-}" ]]; then
    log "ERROR: OPERATOR_IMAGE is required"
    exit 1
fi

OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-openshift-${OPERATOR_NAME}}"
OPERATOR_DEPLOYMENT_NAME="${OPERATOR_DEPLOYMENT_NAME:-${OPERATOR_NAME}}"
CLUSTER_PACKAGE_NAME="${CLUSTER_PACKAGE_NAME:-${OPERATOR_NAME}-e2e-test}"

log "Installing ${OPERATOR_NAME} via PKO ClusterPackage"
log "  ClusterPackage: ${CLUSTER_PACKAGE_NAME}"
log "  PKO image: ${OPERATOR_PKO_IMAGE}"
log "  Operator image: ${OPERATOR_IMAGE}"
log "  Namespace: ${OPERATOR_NAMESPACE}"

# Add CI build cluster registry credentials to the cluster's global pull
# secret so both PKO and nodes can pull CI-built images. Uses oc replace
# with optimistic concurrency (resourceVersion) to avoid race conditions
# when multiple operator jobs share the same lease cluster concurrently.
# Each job's CI creds use a different registry host (e.g., build01 vs
# build11), so a concurrent read-modify-write without CAS can lose one
# job's registry entry when another overwrites the secret.
log "Adding CI registry credentials to cluster pull secret"
KUBECONFIG="" oc registry login --to=/tmp/ci-registry-creds.json 2>/dev/null || true
if [[ -s /tmp/ci-registry-creds.json ]]; then
    CI_REGISTRIES=$(jq -r '.auths | keys | join(", ")' /tmp/ci-registry-creds.json 2>/dev/null || echo "unknown")
    log "CI registries: ${CI_REGISTRIES}"

    for attempt in $(seq 1 5); do
        SECRET_JSON=$(oc get secret pull-secret -n openshift-config -o json)
        CURRENT_PS=$(echo "${SECRET_JSON}" | jq -r '.data[".dockerconfigjson"]' | base64 -d)
        MERGED_PS=$(echo "${CURRENT_PS}" | jq -s '.[0] * .[1]' - /tmp/ci-registry-creds.json)
        MERGED_B64=$(echo "${MERGED_PS}" | base64 -w0 2>/dev/null || echo "${MERGED_PS}" | base64)
        UPDATED=$(echo "${SECRET_JSON}" | jq '.data[".dockerconfigjson"] = "'"${MERGED_B64}"'"')
        if echo "${UPDATED}" | oc replace -f - 2>/dev/null; then
            log "CI registry credentials merged into global pull secret"
            break
        fi
        if [[ ${attempt} -eq 5 ]]; then
            log "ERROR: Failed to update global pull secret after 5 retries"
            exit 1
        else
            log "  Pull secret conflict (attempt ${attempt}), retrying..."
            sleep 1
        fi
    done

    echo "${MERGED_PS}" > /tmp/merged-pull-secret.json
    oc create secret docker-registry ci-pull-secret \
        -n openshift-package-operator \
        --from-file=.dockerconfigjson=/tmp/merged-pull-secret.json \
        --dry-run=client -o yaml | oc apply -f -
    oc patch sa package-operator -n openshift-package-operator \
        --type json -p '[{"op":"add","path":"/imagePullSecrets/-","value":{"name":"ci-pull-secret"}}]' 2>/dev/null || true
    log "CI pull secret added to PKO namespace"

    # Record baseline timestamp before restart so we can verify post-restart reconciliation
    PKO_RESTART_BASELINE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    log "Recording PKO restart baseline timestamp: ${PKO_RESTART_BASELINE}"

    oc rollout restart deployment -n openshift-package-operator 2>/dev/null || true
    oc rollout status deployment -n openshift-package-operator --timeout=120s 2>/dev/null || true
    log "PKO restarted with CI pull secret"

    # PKO readiness gate: verify PKO controllers are actively reconciling
    # post-restart by checking that at least one existing ClusterPackage has
    # a condition lastTransitionTime newer than our pre-restart baseline.
    # This proves controllers are processing, not just showing stale state.
    EXISTING_CPS=$(oc get clusterpackage --no-headers -o custom-columns=':metadata.name' 2>/dev/null || true)
    BASELINE_EPOCH=$(date -d "${PKO_RESTART_BASELINE}" +%s 2>/dev/null || true)
    if [[ -n "${EXISTING_CPS}" && -n "${BASELINE_EPOCH}" ]]; then
        log "Waiting for PKO to reconcile post-restart (baseline: ${PKO_RESTART_BASELINE})..."
        PKO_READY=""
        for i in $(seq 1 12); do
            for cp in ${EXISTING_CPS}; do
                # Get all lastTransitionTime values from status conditions
                TIMESTAMPS=$(oc get clusterpackage "${cp}" \
                    -o jsonpath='{.status.conditions[*].lastTransitionTime}' 2>/dev/null || true)
                for ts in ${TIMESTAMPS}; do
                    TS_EPOCH=$(date -d "${ts}" +%s 2>/dev/null || true)
                    if [[ -n "${TS_EPOCH}" && "${TS_EPOCH}" -gt "${BASELINE_EPOCH}" ]]; then
                        log "PKO is active post-restart: ClusterPackage ${cp} has condition updated at ${ts} (after baseline ${PKO_RESTART_BASELINE})"
                        PKO_READY=1
                        break 2
                    fi
                done
            done
            if [[ -n "${PKO_READY}" ]]; then
                break
            fi
            log "  PKO readiness check attempt ${i}/12: no post-restart condition timestamps yet"
            sleep 5
        done
        if [[ -z "${PKO_READY}" ]]; then
            log "ERROR: PKO readiness could not be verified — no ClusterPackage condition was updated after restart baseline ${PKO_RESTART_BASELINE}"
            log "ERROR: PKO controllers may not be reconciling. Check PKO pod logs for errors."
            for cp in ${EXISTING_CPS}; do
                oc get clusterpackage "${cp}" -o yaml 2>/dev/null || true
            done
            exit 1
        fi
    else
        log "ERROR: PKO readiness could not be verified — no existing ClusterPackages found to validate post-restart reconciliation"
        log "ERROR: At least one ClusterPackage must exist on the cluster for the readiness gate to confirm PKO is operational"
        exit 1
    fi

    # Add CI pull secret to the operator namespace so operator pods can pull
    # CI-built images without waiting for MCO to propagate the global secret.
    oc create namespace "${OPERATOR_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
    oc create secret docker-registry ci-pull-secret \
        -n "${OPERATOR_NAMESPACE}" \
        --from-file=.dockerconfigjson=/tmp/merged-pull-secret.json \
        --dry-run=client -o yaml | oc apply -f -
    log "CI pull secret added to operator namespace ${OPERATOR_NAMESPACE}"

    # Pre-create the operator ServiceAccount with the CI pull secret BEFORE
    # creating the ClusterPackage. Without this, PKO creates a pod using the
    # default (un-patched) SA, causing ErrImagePull. The pod then sits in
    # image-pull-backoff for ~3 minutes until the SA patch + pod delete in the
    # deployment wait loop below kicks in.  By pre-creating the SA with the
    # pull secret already attached, the first pod PKO creates can pull
    # immediately.  The existing SA patch code in the wait loop is kept as a
    # fallback in case PKO uses a different SA name.
    SA_PRECREATE_NAME="${OPERATOR_DEPLOYMENT_NAME:-${OPERATOR_NAME}}"
    log "Pre-creating ServiceAccount ${SA_PRECREATE_NAME} in ${OPERATOR_NAMESPACE} with CI pull secret"
    oc create sa "${SA_PRECREATE_NAME}" -n "${OPERATOR_NAMESPACE}" \
        --dry-run=client -o yaml | oc apply -f -
    # Use strategic-merge patch so this works whether or not the SA already
    # has an imagePullSecrets array.  JSON Patch "add" to "/imagePullSecrets/-"
    # fails when the array does not exist; strategic merge creates it.
    oc patch sa "${SA_PRECREATE_NAME}" -n "${OPERATOR_NAMESPACE}" \
        --type strategic -p '{"imagePullSecrets":[{"name":"ci-pull-secret"}]}'
    log "ServiceAccount ${SA_PRECREATE_NAME} pre-patched with CI pull secret"
else
    log "WARNING: Could not get CI registry credentials, PKO may fail to pull images"
fi

# Save Hive/MCC-managed CR instances before removing the ClusterPackage.
# On managed clusters, Hive SyncSets deploy CRs (RouteMonitors, etc.) that
# we must preserve. We select ONLY Hive-managed CRs via the
# hive.openshift.io/managed=true label — this precisely captures "what to
# preserve" rather than a fragile heuristic (e.g. skipping test-* names).
# The backup is belt-and-suspenders: the primary protection is orphaning
# CRDs before CP deletion (below), but if something goes wrong this backup
# enables CR restoration.
CR_BACKUP_DIR="/tmp/operator-cr-backup"
mkdir -p "${CR_BACKUP_DIR}"
if [[ -n "${OPERATOR_CRDS:-}" ]]; then
    IFS=',' read -ra CRD_LIST <<< "${OPERATOR_CRDS}"
    for crd in "${CRD_LIST[@]}"; do
        crd=$(echo "${crd}" | xargs)
        if oc get crd "${crd}" &>/dev/null; then
            RESOURCE=$(oc get crd "${crd}" -o jsonpath='{.spec.names.plural}')
            GROUP=$(oc get crd "${crd}" -o jsonpath='{.spec.group}')
            log "Backing up Hive-managed ${RESOURCE}.${GROUP} instances (label: hive.openshift.io/managed=true)"
            # Select only Hive-managed CRs and strip server-side fields so
            # the backup re-applies cleanly without conflicts.
            if oc get "${RESOURCE}.${GROUP}" -A -l hive.openshift.io/managed=true -o json 2>/dev/null \
                | jq '
                    .items[] |
                    del(
                        .metadata.resourceVersion,
                        .metadata.uid,
                        .metadata.ownerReferences,
                        .metadata.managedFields,
                        .metadata.creationTimestamp
                    )
                ' > "${CR_BACKUP_DIR}/${crd}.json" 2>/dev/null; then
                CR_COUNT=$(jq -s 'length' "${CR_BACKUP_DIR}/${crd}.json" 2>/dev/null || echo 0)
                log "  Backed up ${CR_COUNT} Hive-managed CR(s) for ${crd}"
            else
                log "  No Hive-managed CRs found for ${crd}"
                : > "${CR_BACKUP_DIR}/${crd}.json"
            fi
        fi
    done
fi

# Back up the production ClusterPackage before deleting it.
# cleanup will restore it so the cluster is not returned to the pool
# missing its production operator (otherwise Hive resync takes ~2h).
if ! PRODUCTION_CP_LOOKUP=$(oc get clusterpackage "${OPERATOR_NAME}" --ignore-not-found -o name 2>/dev/null); then
    log "ERROR: Failed to look up production ClusterPackage ${OPERATOR_NAME}"
    exit 1
fi
if [[ -n "${PRODUCTION_CP_LOOKUP}" ]]; then
    log "Backing up production ClusterPackage ${OPERATOR_NAME}"
    backup_file="${SHARED_DIR}/production-clusterpackage.yaml"
    if ! temporary_backup="$(mktemp "${SHARED_DIR}/production-clusterpackage.XXXXXX" 2>/dev/null)"; then
        log "ERROR: Failed to create production ClusterPackage backup"
        exit 1
    fi
    if ! oc get clusterpackage "${OPERATOR_NAME}" -o json 2>/dev/null \
      | jq 'del(.status, .metadata.resourceVersion, .metadata.uid, .metadata.generation, .metadata.creationTimestamp, .metadata.ownerReferences, .metadata.finalizers, .metadata.managedFields, .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"])' 2>/dev/null \
      > "${temporary_backup}"; then
        rm -f "${temporary_backup}"
        log "ERROR: Failed to back up production ClusterPackage ${OPERATOR_NAME}"
        exit 1
    fi
    if ! mv "${temporary_backup}" "${backup_file}" 2>/dev/null; then
        rm -f "${temporary_backup}"
        log "ERROR: Failed to save production ClusterPackage backup"
        exit 1
    fi
    log "Production ClusterPackage backed up to SHARED_DIR"
fi

# ──────────────────────────────────────────────────────────────────────
# CRITICAL: Orphan CRDs BEFORE deleting the ClusterPackage.
# ──────────────────────────────────────────────────────────────────────
# Cascade chain: CP → owns → ClusterObjectSets → own → CRDs (via ownerRefs)
# If we delete CP first, PKO deletes the COS, and the COS deletion
# cascade-deletes CRDs (via ownerReferences), which in turn removes ALL
# CR instances — including Hive-managed CRs (RouteMonitors, etc.).
# By clearing ownerReferences FIRST, CRDs survive COS deletion and CRs
# are preserved.
if [[ -n "${OPERATOR_CRDS:-}" ]]; then
    log "Orphaning CRDs from ClusterObjectSets BEFORE ClusterPackage deletion (prevents cascade-deletion of CRs)"
    orphan_failed=false
    IFS=',' read -ra CRD_LIST <<< "${OPERATOR_CRDS}"
    for crd in "${CRD_LIST[@]}"; do
        crd=$(echo "${crd}" | xargs)
        if CRD_LOOKUP=$(oc get crd "${crd}" --ignore-not-found -o name 2>/dev/null); then
            if [[ -z "${CRD_LOOKUP}" ]]; then
                log "  CRD ${crd} is absent; no ownership to clear"
                continue
            fi
            log "  Clearing ownerReferences on CRD ${crd}"
            oc patch crd "${crd}" --type merge -p '{"metadata":{"ownerReferences":[],"labels":{"package-operator.run/instance":"'"${CLUSTER_PACKAGE_NAME}"'"}}}' 2>/dev/null || { log "ERROR: Failed to orphan CRD ${crd}"; orphan_failed=true; }
        else
            log "ERROR: Failed to look up CRD ${crd}"
            orphan_failed=true
        fi
    done
    if [[ "${orphan_failed}" == "true" ]]; then
        log "ERROR: Refusing to delete ClusterPackage — CRD orphan patches failed, cascade protection is incomplete"
        exit 1
    fi
fi

# Remove existing operator resources that conflict with PKO adoption.
# On managed clusters, operators are pre-deployed via SSS/PKO. PKO refuses
# to adopt CRDs owned by a different ClusterObjectSet. We remove:
# 1. The existing ClusterPackage (releases the ClusterObjectSet)
# 2. Orphaned ClusterObjectSets (releases CRD ownerReferences)
# CRD ownerReferences are already cleared above to prevent cascade deletion.
# Safe on ephemeral clusters only.
if oc get clusterpackage "${OPERATOR_NAME}" &>/dev/null; then
    log "Removing existing ClusterPackage ${OPERATOR_NAME}"
    oc delete clusterpackage "${OPERATOR_NAME}" --timeout=120s || true
    # Wait for the resource to be fully gone before recreating with the same name.
    # PKO finalizers can delay actual deletion beyond what --timeout reports.
    # Use --ignore-not-found so a 404 returns empty output (exit 0) while
    # transient API errors still produce a non-empty error and non-zero exit.
    for i in $(seq 1 24); do
        RESULT=$(oc get clusterpackage "${OPERATOR_NAME}" --ignore-not-found -o name 2>&1) || true
        if [[ -z "${RESULT}" ]]; then
            break
        fi
        if [[ $i -eq 24 ]]; then
            log "WARNING: ClusterPackage ${OPERATOR_NAME} still exists after 2 minutes, forcing removal"
            oc patch clusterpackage "${OPERATOR_NAME}" --type merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        fi
        sleep 5
    done
    # Confirm deletion after force-removal
    RESULT=$(oc get clusterpackage "${OPERATOR_NAME}" --ignore-not-found -o name 2>&1) || true
    if [[ -n "${RESULT}" ]]; then
        log "ERROR: ClusterPackage ${OPERATOR_NAME} could not be removed: ${RESULT}"
        exit 1
    fi
fi

# Remove orphaned ClusterObjectSets from the old package
for cos in $(oc get clusterobjectset -o name 2>/dev/null | grep "${OPERATOR_NAME}" | grep -v "${CLUSTER_PACKAGE_NAME}" || true); do
    log "Removing orphaned ${cos}"
    # Remove finalizers first to avoid hanging deletes
    oc patch "${cos}" --type merge -p '{"metadata":{"finalizers":[]}}' || true
    oc delete "${cos}" --timeout=60s || true
done

# Also remove any leftover e2e ClusterPackage from a previous run
if [[ "${CLUSTER_PACKAGE_NAME}" != "${OPERATOR_NAME}" ]]; then
    RESULT=$(oc get clusterpackage "${CLUSTER_PACKAGE_NAME}" --ignore-not-found -o name 2>&1) || true
    if [[ -n "${RESULT}" ]]; then
        log "Removing leftover e2e ClusterPackage ${CLUSTER_PACKAGE_NAME}"
        oc delete clusterpackage "${CLUSTER_PACKAGE_NAME}" --timeout=60s || true
        for i in $(seq 1 12); do
            RESULT=$(oc get clusterpackage "${CLUSTER_PACKAGE_NAME}" --ignore-not-found -o name 2>&1) || true
            if [[ -z "${RESULT}" ]]; then
                break
            fi
            if [[ $i -eq 12 ]]; then
                log "WARNING: ClusterPackage ${CLUSTER_PACKAGE_NAME} still exists, forcing removal"
                oc patch clusterpackage "${CLUSTER_PACKAGE_NAME}" --type merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
            fi
            sleep 5
        done
        RESULT=$(oc get clusterpackage "${CLUSTER_PACKAGE_NAME}" --ignore-not-found -o name 2>&1) || true
        if [[ -n "${RESULT}" ]]; then
            log "ERROR: ClusterPackage ${CLUSTER_PACKAGE_NAME} could not be removed: ${RESULT}"
            exit 1
        fi
    fi
fi

# Create the ClusterPackage CR
PKO_CONFIG="    image: ${OPERATOR_IMAGE}"
if [[ -n "${PKO_CONFIG_NAMESPACE:-}" ]]; then
    PKO_CONFIG="${PKO_CONFIG}
    namespace: ${PKO_CONFIG_NAMESPACE}"
fi
cat <<EOF | oc apply -f -
apiVersion: package-operator.run/v1alpha1
kind: ClusterPackage
metadata:
  name: ${CLUSTER_PACKAGE_NAME}
  annotations:
    package-operator.run/collision-protection: None
spec:
  image: ${OPERATOR_PKO_IMAGE}
  config:
${PKO_CONFIG}
EOF

# Save the ClusterPackage name for cleanup
if [[ -n "${SHARED_DIR:-}" ]]; then
    echo "${CLUSTER_PACKAGE_NAME}" > "${SHARED_DIR}/operator-e2e-clusterpackage"
    echo "${OPERATOR_NAMESPACE}" > "${SHARED_DIR}/operator-e2e-namespace"
fi

# Wait for PKO to reconcile and create the deployment
log "Waiting for deployment ${OPERATOR_DEPLOYMENT_NAME} to exist..."
for i in $(seq 1 30); do
    if oc get deployment "${OPERATOR_DEPLOYMENT_NAME}" -n "${OPERATOR_NAMESPACE}" &>/dev/null; then
        break
    fi
    # Poll ClusterPackage status for progress and early error detection
    CP_PHASE=$(oc get clusterpackage "${CLUSTER_PACKAGE_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ -n "${CP_PHASE}" ]]; then
        log "  ClusterPackage ${CLUSTER_PACKAGE_NAME} phase: ${CP_PHASE} (attempt ${i}/30)"
        if [[ "${CP_PHASE}" == "Invalid" || "${CP_PHASE}" == *"Error"* ]]; then
            log "ERROR: ClusterPackage ${CLUSTER_PACKAGE_NAME} has terminal phase: ${CP_PHASE}"
            oc get clusterpackage "${CLUSTER_PACKAGE_NAME}" -o yaml 2>/dev/null || true
            oc get clusterobjectset -o wide 2>/dev/null || true
            exit 1
        fi
    else
        log "  ClusterPackage ${CLUSTER_PACKAGE_NAME} phase: <not set> (attempt ${i}/30)"
    fi
    if [[ $i -eq 30 ]]; then
        log "ERROR: Deployment ${OPERATOR_DEPLOYMENT_NAME} not found after 5 minutes"
        oc get clusterpackage "${CLUSTER_PACKAGE_NAME}" -o yaml || true
        oc get clusterobjectset -o wide 2>/dev/null | grep "${OPERATOR_NAME}" || true
        exit 1
    fi
    sleep 10
done

# Wait for the operator deployment to be available. During PKO
# reconciliation the deployment can briefly vanish, so retry oc wait
# on NotFound instead of failing immediately. Patch the SA with CI
# pull secret on the first stable sighting of the deployment.
SA_PATCHED=""
log "Waiting for deployment ${OPERATOR_DEPLOYMENT_NAME} to be ready..."
for attempt in $(seq 1 30); do
    if ! oc get deployment "${OPERATOR_DEPLOYMENT_NAME}" -n "${OPERATOR_NAMESPACE}" &>/dev/null; then
        sleep 10
        continue
    fi

    if [[ -z "${SA_PATCHED}" ]] && oc get secret ci-pull-secret -n "${OPERATOR_NAMESPACE}" &>/dev/null; then
        SA_NAME=$(oc get deployment "${OPERATOR_DEPLOYMENT_NAME}" -n "${OPERATOR_NAMESPACE}" \
            -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || echo "${OPERATOR_NAME}")
        if oc get sa "${SA_NAME}" -n "${OPERATOR_NAMESPACE}" &>/dev/null; then
            oc patch sa "${SA_NAME}" -n "${OPERATOR_NAMESPACE}" \
                --type json -p '[{"op":"add","path":"/imagePullSecrets/-","value":{"name":"ci-pull-secret"}}]' 2>/dev/null || true
            log "CI pull secret added to ServiceAccount ${SA_NAME}"
            oc delete pods -n "${OPERATOR_NAMESPACE}" -l app="${OPERATOR_DEPLOYMENT_NAME}" 2>/dev/null || true
            SA_PATCHED=1
        fi
    fi

    if oc wait deployment "${OPERATOR_DEPLOYMENT_NAME}" -n "${OPERATOR_NAMESPACE}" \
        --for=condition=Available --timeout=30s 2>/dev/null; then
        break
    fi

    if [[ ${attempt} -eq 30 ]]; then
        log "ERROR: Deployment ${OPERATOR_DEPLOYMENT_NAME} not ready after 5 minutes"
        oc get deployment "${OPERATOR_DEPLOYMENT_NAME}" -n "${OPERATOR_NAMESPACE}" -o yaml 2>/dev/null || true
        oc get pods -n "${OPERATOR_NAMESPACE}" 2>/dev/null || true
        exit 1
    fi
done

log "${OPERATOR_NAME} installed and ready in ${OPERATOR_NAMESPACE}"

# Wait for operator CRDs to be established before restoring CRs or
# handing off to the e2e test step.  Without this gate the API server's
# REST mapper may not yet serve the CRD kinds, causing NoKindMatchError
# failures in downstream steps.
if [[ -n "${OPERATOR_CRDS:-}" ]]; then
    IFS=',' read -ra CRD_LIST <<< "${OPERATOR_CRDS}"
    for crd in "${CRD_LIST[@]}"; do
        crd=$(echo "${crd}" | xargs)
        log "Waiting for CRD ${crd} to be established..."
        if ! oc wait crd "${crd}" --for=condition=Established --timeout=60s; then
            log "ERROR: CRD ${crd} not established after 60s"
            oc get crd "${crd}" -o yaml 2>/dev/null || true
            exit 1
        fi
    done
    log "All operator CRDs established"

    # Verify each CRD is actually served by the API server.
    # condition=Established only means the CRD *object* has that status
    # condition, but it does NOT guarantee the API server is serving the
    # resource yet.  Without this check the operator (or e2e tests) can
    # hit "the server could not find the requested resource" errors and
    # never recover.  Poll `oc get <plural>.<group>` until the API
    # server responds without error.
    for crd in "${CRD_LIST[@]}"; do
        crd=$(echo "${crd}" | xargs)
        CRD_PLURAL=$(oc get crd "${crd}" -o jsonpath='{.spec.names.plural}')
        CRD_GROUP=$(oc get crd "${crd}" -o jsonpath='{.spec.group}')
        log "Verifying API server serves ${CRD_PLURAL}.${CRD_GROUP}..."
        for i in $(seq 1 24); do
            if oc get "${CRD_PLURAL}.${CRD_GROUP}" -A --no-headers --request-timeout=10s 2>/dev/null; then
                break
            fi
            if [[ $i -eq 24 ]]; then
                log "ERROR: CRD ${crd} established but API server not serving ${CRD_PLURAL}.${CRD_GROUP} after 120s"
                oc get crd "${crd}" -o yaml 2>/dev/null || true
                oc api-resources 2>/dev/null | grep -i "${CRD_PLURAL}" || true
                exit 1
            fi
            sleep 5
        done
        log "CRD ${CRD_PLURAL}.${CRD_GROUP} is served by API server"
    done
fi

# Restore backed-up Hive-managed CR instances (belt-and-suspenders).
# These were exported as individual JSON objects; wrap in a list for oc apply.
for backup in "${CR_BACKUP_DIR}"/*.json; do
    [[ -f "${backup}" ]] || continue
    if [[ -s "${backup}" ]]; then
        crd_name=$(basename "${backup}" .json)
        log "Restoring Hive-managed CR instances for ${crd_name}"
        if ! jq -s '{apiVersion: "v1", kind: "List", items: .}' "${backup}" 2>/dev/null \
            | oc apply -f - 2>/dev/null; then
            log "ERROR: Failed to restore Hive-managed CR instances for ${crd_name} from ${backup}"
            exit 1
        fi
    fi
done

# ──────────────────────────────────────────────────────────────────────
# Post-restore handoff gate: verify required CRs exist.
# ──────────────────────────────────────────────────────────────────────
# After CP swap and CRD re-establishment, confirm that Hive-managed CRs
# are present. If a CR is missing (e.g. Hive SyncSet hasn't resynced yet),
# poll for up to 120s. Hard-fail if still absent — better to fail here
# with a clear error than hand off to e2e tests that will time out with
# a cryptic "resource not found".
# Format: comma-separated "plural.group/name[/namespace]"
#   Namespaced: routemonitors.monitoring.openshift.io/console/openshift-route-monitor-operator
#   Namespaced: clusterurlmonitors.monitoring.openshift.io/api/openshift-route-monitor-operator
if [[ -n "${OPERATOR_REQUIRED_CRS:-}" ]]; then
    log "Verifying required CRs exist (OPERATOR_REQUIRED_CRS)"
    IFS=',' read -ra REQUIRED_LIST <<< "${OPERATOR_REQUIRED_CRS}"
    for entry in "${REQUIRED_LIST[@]}"; do
        entry=$(echo "${entry}" | xargs)
        [[ -z "${entry}" ]] && continue

        # Parse: plural.group/name[/namespace]
        RESOURCE_TYPE="${entry%%/*}"
        REMAINDER="${entry#*/}"
        CR_NAME="${REMAINDER%%/*}"
        CR_NAMESPACE=""
        if [[ "${REMAINDER}" == */* ]]; then
            CR_NAMESPACE="${REMAINDER#*/}"
        fi

        NS_FLAG=""
        NS_DISPLAY=""
        if [[ -n "${CR_NAMESPACE}" ]]; then
            NS_FLAG="-n ${CR_NAMESPACE}"
            NS_DISPLAY=" in namespace ${CR_NAMESPACE}"
        fi

        log "Checking for required CR: ${CR_NAME} (${RESOURCE_TYPE})${NS_DISPLAY}"

        CR_FOUND=false
        for i in $(seq 1 24); do
            # shellcheck disable=SC2086
            if oc get "${RESOURCE_TYPE}" "${CR_NAME}" ${NS_FLAG} &>/dev/null; then
                CR_FOUND=true
                log "  Required CR ${CR_NAME} exists"
                break
            fi
            if [[ $i -eq 1 ]]; then
                log "  CR ${CR_NAME} not found, polling up to 120s for Hive SyncSet resync..."
            fi
            sleep 5
        done

        if [[ "${CR_FOUND}" != "true" ]]; then
            log "ERROR: Required CR ${CR_NAME} (${RESOURCE_TYPE})${NS_DISPLAY} not found after 120s"
            log "ERROR: This CR is expected to be deployed by Hive SyncSet. The ClusterPackage swap may have cascade-deleted it."
            log "ERROR: Check whether CRD ownerReferences were properly cleared before ClusterPackage deletion."
            exit 1
        fi
    done
    log "All required CRs verified"
fi

# Wait for additional operator-managed deployments to become ready.
# Some operators create secondary deployments (e.g., ocm-agent-operator
# creates an ocm-agent Deployment) after reconciling their CRs.
if [[ -n "${OPERATOR_WAIT_DEPLOYMENTS:-}" ]]; then
    IFS=',' read -ra WAIT_DEPS <<< "${OPERATOR_WAIT_DEPLOYMENTS}"
    for dep in "${WAIT_DEPS[@]}"; do
        dep=$(echo "${dep}" | xargs)
        log "Waiting for secondary deployment ${dep} to exist..."
        for _i in $(seq 1 30); do
            if oc get deployment "${dep}" -n "${OPERATOR_NAMESPACE}" &>/dev/null; then
                break
            fi
            sleep 10
        done
        if oc get deployment "${dep}" -n "${OPERATOR_NAMESPACE}" &>/dev/null; then
            log "Waiting for deployment ${dep} to be ready..."
            if ! oc wait deployment "${dep}" -n "${OPERATOR_NAMESPACE}" \
                --for=condition=Available --timeout=300s; then
                log "ERROR: deployment ${dep} not ready after 5 minutes"
                oc get deployment "${dep}" -n "${OPERATOR_NAMESPACE}" -o yaml 2>/dev/null || true
                oc get pods -n "${OPERATOR_NAMESPACE}" -l app="${dep}" 2>/dev/null || true
                exit 1
            fi
        else
            log "ERROR: deployment ${dep} not found after 5 minutes"
            exit 1
        fi
    done
fi
