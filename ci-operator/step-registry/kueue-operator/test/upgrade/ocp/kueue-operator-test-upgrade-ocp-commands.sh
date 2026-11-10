#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

TARGET="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"
TARGET_VERSION="$(oc adm release info "${TARGET}" -o jsonpath='{.metadata.version}')"
SOURCE_VERSION="$(oc get clusterversion version -o jsonpath='{.status.desired.version}')"

echo "Upgrading from ${SOURCE_VERSION} to ${TARGET_VERSION}..."
oc get clusterversion version
echo ""

echo "Verifying kueue operator before upgrade..."
oc get deployment -n openshift-kueue-operator
oc get pods -n openshift-kueue-operator
echo ""

echo "Triggering upgrade..."
oc adm upgrade --to-image="${TARGET}" --allow-explicit-upgrade --force
echo "Upgrade initiated, waiting for completion..."

TIMEOUT=7200
INTERVAL=60
ELAPSED=0

while (( ELAPSED < TIMEOUT )); do
    sleep "${INTERVAL}"
    ELAPSED=$(( ELAPSED + INTERVAL ))

    AVAIL="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")"
    PROG="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo "Unknown")"
    HIST_VER="$(oc get clusterversion version -o jsonpath='{.status.history[0].version}' 2>/dev/null || echo "")"
    HIST_STATE="$(oc get clusterversion version -o jsonpath='{.status.history[0].state}' 2>/dev/null || echo "")"

    echo "[$(( ELAPSED / 60 ))m] Available=${AVAIL} Progressing=${PROG} Version=${HIST_VER} State=${HIST_STATE}"

    if [[ "${AVAIL}" == "True" && "${PROG}" == "False" && "${HIST_VER}" == "${TARGET_VERSION}" && "${HIST_STATE}" == "Completed" ]]; then
        echo ""
        echo "Upgrade to ${TARGET_VERSION} completed!"
        oc get clusterversion version
        echo ""

        echo "Waiting for cluster to stabilize..."
        oc adm wait-for-stable-cluster --minimum-stable-period=2m --timeout=30m || {
            echo "WARN: cluster not fully stable"
            oc get co --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False"'
        }

        echo ""
        echo "Verifying kueue operator after upgrade..."
        oc get pods -n openshift-kueue-operator
        oc get deployment -n openshift-kueue-operator
        exit 0
    fi
done

echo "ERROR: Upgrade timed out after $(( TIMEOUT / 60 )) minutes"
oc get clusterversion version -o yaml
oc get co --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False"'
exit 1
