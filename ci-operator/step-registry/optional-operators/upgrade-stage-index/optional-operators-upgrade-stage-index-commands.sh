#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# In rehearsals the upgrade env vars may be unset; only enforce them for real jobs.
if [[ $JOB_NAME != rehearse-* ]]; then
    if [[ -z ${STAGE_OO_INDEX:-} ]] || [[ -z ${OO_CHANNEL:-} ]] || [[ -z ${OO_LATEST_CSV:-} ]]; then
        echo "[$(date --utc +%FT%T.%3NZ)] At least one of required variables STAGE_OO_INDEX=${STAGE_OO_INDEX:-} OO_CHANNEL=${OO_CHANNEL:-} OO_LATEST_CSV=${OO_LATEST_CSV:-} is unset"
        echo "[$(date --utc +%FT%T.%3NZ)] Variables are only allowed to be unset in rehearsals"
        echo "[$(date --utc +%FT%T.%3NZ)] Script Completed Execution With Failures !"
        exit 1
    fi
fi

# For disconnected or otherwise unreachable environments, route through the proxy.
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Load the install namespace and subscription recorded by the subscribe step.
OO_INSTALL_NAMESPACE=$(cat "${SHARED_DIR}/oo-install-namespace")
SUB=$(cat "${SHARED_DIR}/oo-subscription")

CS_NAMESPACE="openshift-marketplace"
CATSRC="${OO_PACKAGE:-operator}-stage-index"

echo "[$(date --utc +%FT%T.%3NZ)] == Parameters:"
echo "[$(date --utc +%FT%T.%3NZ)] STAGE_OO_INDEX:       $STAGE_OO_INDEX"
echo "[$(date --utc +%FT%T.%3NZ)] OO_PACKAGE:           ${OO_PACKAGE:-}"
echo "[$(date --utc +%FT%T.%3NZ)] OO_CHANNEL:           $OO_CHANNEL"
echo "[$(date --utc +%FT%T.%3NZ)] OO_LATEST_CSV:        $OO_LATEST_CSV"
echo "[$(date --utc +%FT%T.%3NZ)] OO_INSTALL_NAMESPACE: $OO_INSTALL_NAMESPACE"
echo "[$(date --utc +%FT%T.%3NZ)] SUB:                  $SUB"

# The securityContextConfig API field defaults to "restricted" enforcement since
# OCP 4.14; use it for the grpc catalog pod on 4.12+.
CS_PODCONFIG=""
OCP_VERSION=$(oc version | grep "Server Version" | cut -d ':' -f2 | xargs)
OCP_MAJOR_VERSION=$(echo "$OCP_VERSION" | cut -d '.' -f1)
OCP_MINOR_VERSION=$(echo "$OCP_VERSION" | cut -d '.' -f2)
if [ "$OCP_MAJOR_VERSION" -ge "5" ] || { [ "$OCP_MAJOR_VERSION" -eq "4" ] && [ "$OCP_MINOR_VERSION" -gt "11" ]; }; then
    CS_PODCONFIG=$(cat <<EOF
  grpcPodConfig:
    securityContextConfig: restricted
EOF
)
fi

echo "[$(date --utc +%FT%T.%3NZ)] Creating stage CatalogSource \"$CATSRC\" in \"$CS_NAMESPACE\" from \"$STAGE_OO_INDEX\""
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $CATSRC
  namespace: $CS_NAMESPACE
  annotations:
    openshift.io/required-scc: restricted-v2
spec:
  sourceType: grpc
  image: "$STAGE_OO_INDEX"
$CS_PODCONFIG
EOF

# Wait up to 10 minutes for the stage CatalogSource to become READY.
IS_CATSRC_READY=false
for i in $(seq 1 120); do
    CATSRC_STATE=$(oc get catalogsource "$CATSRC" -n "$CS_NAMESPACE" -o jsonpath='{.status.connectionState.lastObservedState}' || true)
    echo "[$(date --utc +%FT%T.%3NZ)] CatalogSource state: ${CATSRC_STATE:-<none>}"
    if [ "$CATSRC_STATE" = "READY" ]; then
        echo "[$(date --utc +%FT%T.%3NZ)] Stage CatalogSource ready after $((5*i)) seconds"
        IS_CATSRC_READY=true
        break
    fi
    sleep 5
done

if [ "$IS_CATSRC_READY" = false ]; then
    echo "[$(date --utc +%FT%T.%3NZ)] Timed out waiting for stage CatalogSource \"$CATSRC\" to become ready"
    oc get catalogsource "$CATSRC" -n "$CS_NAMESPACE" -o yaml >"$ARTIFACT_DIR/cs-$CATSRC.yaml" || true
    echo "[$(date --utc +%FT%T.%3NZ)] Script Completed Execution With Failures !"
    exit 1
fi

# Give OLM a moment to register the new catalog before repointing the Subscription.
sleep 10

DEPLOYMENT_UPGRADE_START_TIME=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
echo "[$(date --utc +%FT%T.%3NZ)] Set the deployment upgrade start time: ${DEPLOYMENT_UPGRADE_START_TIME}"

echo "[$(date --utc +%FT%T.%3NZ)] Repointing Subscription \"$SUB\" at stage CatalogSource with Manual approval"
oc -n "$OO_INSTALL_NAMESPACE" patch subscription "$SUB" --type merge --patch \
  '{"spec":{"source":"'"$CATSRC"'","sourceNamespace":"'"$CS_NAMESPACE"'","channel":"'"$OO_CHANNEL"'","installPlanApproval":"Manual"}}'

# Approve the InstallPlan carrying OO_LATEST_CSV. Wait up to 10 minutes for it to appear.
approve_upgrade_installplan () {
    for _ in $(seq 1 120); do
        # Find an InstallPlan in the namespace that references the target CSV.
        IP=$(oc -n "$OO_INSTALL_NAMESPACE" get installplan \
            -o jsonpath='{range .items[?(@.spec.approved==false)]}{.metadata.name}{" "}{.spec.clusterServiceVersionNames}{"\n"}{end}' 2>/dev/null \
            | grep -F "$OO_LATEST_CSV" | head -n1 | awk '{print $1}' || true)
        if [[ -n "$IP" ]]; then
            echo "[$(date --utc +%FT%T.%3NZ)] Approving InstallPlan \"$IP\" for CSV \"$OO_LATEST_CSV\""
            oc -n "$OO_INSTALL_NAMESPACE" patch installplan "$IP" --type merge --patch '{"spec":{"approved":true}}'
            return 0
        fi
        sleep 5
    done
    echo "[$(date --utc +%FT%T.%3NZ)] Timed out waiting for an InstallPlan carrying CSV \"$OO_LATEST_CSV\""
    return 1
}

approve_upgrade_installplan || true

echo "[$(date --utc +%FT%T.%3NZ)] Waiting for ClusterServiceVersion \"$OO_LATEST_CSV\" to become ready..."

# Wait up to 30 minutes for the upgrade to complete.
for _ in $(seq 1 180); do
    # A later InstallPlan may be generated by OLM; keep approving pending ones for the target CSV.
    approve_upgrade_installplan >/dev/null 2>&1 || true
    CSV=$(oc -n "$OO_INSTALL_NAMESPACE" get subscription "$SUB" -o jsonpath='{.status.installedCSV}' || true)
    if [[ "$CSV" == "$OO_LATEST_CSV" ]]; then
        if [[ "$(oc -n "$OO_INSTALL_NAMESPACE" get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
            echo "[$(date --utc +%FT%T.%3NZ)] ClusterServiceVersion \"$CSV\" ready"

            DEPLOYMENT_UPGRADE_ART="deployment_upgrade_details.yaml"
            cat > "${ARTIFACT_DIR}/${DEPLOYMENT_UPGRADE_ART}" <<EOF
---
csv: "${CSV}"
subscription: "${SUB}"
catalogsource: "${CATSRC}"
install_namespace: "${OO_INSTALL_NAMESPACE}"
stage_index: "${STAGE_OO_INDEX}"
deployment_start_time: "${DEPLOYMENT_UPGRADE_START_TIME}"
EOF
            cp "${ARTIFACT_DIR}/${DEPLOYMENT_UPGRADE_ART}" "${SHARED_DIR}/${DEPLOYMENT_UPGRADE_ART}"
            echo "[$(date --utc +%FT%T.%3NZ)] Script Completed Execution Successfully !"
            exit 0
        fi
    fi
    sleep 10
done

echo "[$(date --utc +%FT%T.%3NZ)] Timed out waiting for CSV \"$OO_LATEST_CSV\" to become ready"

# Dump artifacts for debugging.
oc get namespace "$OO_INSTALL_NAMESPACE" -o yaml >"$ARTIFACT_DIR/ns-$OO_INSTALL_NAMESPACE.yaml" || true
oc get -n "$CS_NAMESPACE" catalogsource "$CATSRC" -o yaml >"$ARTIFACT_DIR/cs-$CATSRC.yaml" || true
oc get -n "$OO_INSTALL_NAMESPACE" subscription "$SUB" -o yaml >"$ARTIFACT_DIR/sub-$SUB.yaml" || true
oc get -n "$OO_INSTALL_NAMESPACE" installplans -o yaml >"$ARTIFACT_DIR/installPlans.yaml" || true
oc get -n "$OO_INSTALL_NAMESPACE" csv -o yaml >"$ARTIFACT_DIR/$OO_INSTALL_NAMESPACE-all-csvs.yaml" || true

echo "[$(date --utc +%FT%T.%3NZ)] Script Completed Execution With Failures !"
exit 1
