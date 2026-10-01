#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# load stored install namespace and subscription from shared dir
OO_INSTALL_NAMESPACE=$(cat "${SHARED_DIR}"/oo-install-namespace)
SUB=$(cat "${SHARED_DIR}"/oo-subscription)

DEPLOYMENT_UPGRADE_START_TIME=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
echo "Set the deployment upgrade start time: ${DEPLOYMENT_UPGRADE_START_TIME}"

oc -n "$OO_INSTALL_NAMESPACE" patch subscription "${SUB}" --type merge --patch '{"spec":{"channel":"'"${OO_CHANNEL}"'","installPlanApproval":"Automatic"}}'

echo "Subscription channel updated and installPlan set to Automatic"
echo "Waiting for ClusterServiceVersion to become ready..."

# wait 30 minutes for operator upgrade to complete
for _ in $(seq 1 180); do
    CSV=$(oc -n "$OO_INSTALL_NAMESPACE" get subscription "$SUB" -o jsonpath='{.status.installedCSV}' || true)
    if [[ "$CSV" == "${OO_LATEST_CSV}" ]]; then
        if [[ "$(oc -n "$OO_INSTALL_NAMESPACE" get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
            echo "ClusterServiceVersion \"$CSV\" ready"

            DEPLOYMENT_UPGRADE_ART="oo_deployment_upgrade_details.yaml"
            echo "Saving deployment upgrade details in ${DEPLOYMENT_UPGRADE_ART} as a shared artifact"
            cat > "${ARTIFACT_DIR}/${DEPLOYMENT_UPGRADE_ART}" <<EOF
---
csv: "${CSV}"
subscription: "{SUB}"
install_namespace: "${OO_INSTALL_NAMESPACE}"
deployment_start_time: "${DEPLOYMENT_UPGRADE_START_TIME}"
EOF
            cp "${ARTIFACT_DIR}/${DEPLOYMENT_UPGRADE_ART}" "${SHARED_DIR}/${DEPLOYMENT_UPGRADE_ART}"
            exit 0
        fi
    fi
    sleep 10
done

echo "Timed out waiting for csv to become ready"

NS_ART="$ARTIFACT_DIR/ns-$OO_INSTALL_NAMESPACE.yaml"
echo "Dumping Namespace $OO_INSTALL_NAMESPACE as $NS_ART"
oc get namespace "$OO_INSTALL_NAMESPACE" -o yaml >"$NS_ART"

SUB_ART="$ARTIFACT_DIR/sub-$SUB.yaml"
echo "Dumping Subscription $SUB as $SUB_ART"
oc get -n "$OO_INSTALL_NAMESPACE" subscription "$SUB" -o yaml >"$SUB_ART"
for field in state reason; do
    VALUE="$(oc get -n "$OO_INSTALL_NAMESPACE" subscription "$SUB" -o jsonpath="{.status.$field}" || true)"
    if [[ -n "$VALUE" ]]; then
        echo "  Subscription $SUB status $field: $VALUE"
    fi
done

if [[ -n "$CSV" ]]; then
    CSV_ART="$ARTIFACT_DIR/csv-$CSV.yaml"
    echo "ClusterServiceVersion $CSV was created but never became ready"
    echo "Dumping ClusterServiceVersion $CSV as $CSV_ART"
    oc get -n "$OO_INSTALL_NAMESPACE" csv "$CSV" -o yaml >"$CSV_ART"
    for field in phase message reason; do
        VALUE="$(oc get -n "$OO_INSTALL_NAMESPACE" csv "$CSV" -o jsonpath="{.status.$field}" || true)"
        if [[ -n "$VALUE" ]]; then
            echo "  ClusterServiceVersion $CSV status $field: $VALUE"
        fi
    done
else
    CSV_ART="$ARTIFACT_DIR/$OO_INSTALL_NAMESPACE-all-csvs.yaml"
    echo "ClusterServiceVersion $CSV was never created"
    echo "Dumping all ClusterServiceVersions in namespace $OO_INSTALL_NAMESPACE to $CSV_ART"
    oc get -n "$OO_INSTALL_NAMESPACE" csv -o yaml >"$CSV_ART"
fi
exit 1
