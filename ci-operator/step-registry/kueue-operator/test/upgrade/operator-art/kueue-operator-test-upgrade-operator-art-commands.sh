#!/bin/bash

set -euo pipefail

# In-channel (z-stream) Kueue operator upgrade on the ART build.
#
# The previous z-stream is already installed (Manual InstallPlan approval). Once it
# is running, OLM creates an unapproved InstallPlan for the channel head; approving
# it performs the real OLM upgrade along the replaces edge. No operator-sdk, no
# Subscription deletion, no CSV patching.

source "${SHARED_DIR}/env"
NS=openshift-kueue-operator
PACKAGE=kueue-operator
: "${KUEUE_UPGRADE_FROM_CSV:?the resolve step did not provide KUEUE_UPGRADE_FROM_CSV}"
: "${KUEUE_UPGRADE_TO_CSV:?the resolve step did not provide KUEUE_UPGRADE_TO_CSV}"

echo "State before upgrade:"
oc get subscription,csv -n "${NS}" 2>/dev/null || true

INSTALLED=$(oc get subscription "${PACKAGE}" -n "${NS}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
echo "Installed CSV before upgrade: ${INSTALLED} (expected ${KUEUE_UPGRADE_FROM_CSV})"

approve_installplan_for() {
    local target="$1" ip=""
    for _ in $(seq 1 60); do
        ip=$(oc get installplan -n "${NS}" -o json | jq -r --arg c "${target}" \
            '.items[] | select(.spec.approved == false) | select(.spec.clusterServiceVersionNames[]? == $c) | .metadata.name' | head -n 1)
        [[ -n "${ip}" ]] && break
        sleep 5
    done
    if [[ -z "${ip}" ]]; then
        echo "ERROR: no pending InstallPlan for ${target}"
        oc get installplan -n "${NS}" -o wide 2>/dev/null || true
        oc get subscription "${PACKAGE}" -n "${NS}" -o yaml 2>/dev/null || true
        return 1
    fi
    echo "Approving InstallPlan ${ip} for ${target}"
    oc patch installplan "${ip}" -n "${NS}" --type=merge -p '{"spec":{"approved":true}}'
}

# Poll for the CSV to exist and reach Succeeded. `oc wait --for=jsonpath` errors
# immediately when the CSV does not exist yet (OLM creates it after approval), so a
# bounded poll is used instead.
wait_csv_succeeded() {
    local csv="$1" phase=""
    for _ in $(seq 1 60); do
        phase=$(oc get csv "${csv}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
        [[ "${phase}" == "Succeeded" ]] && return 0
        sleep 10
    done
    echo "ERROR: CSV ${csv} did not reach Succeeded within 10m (last phase: ${phase:-<absent>})"
    oc get csv -n "${NS}" 2>/dev/null || true
    return 1
}

echo "Upgrading ${KUEUE_UPGRADE_FROM_CSV} -> ${KUEUE_UPGRADE_TO_CSV} (in-channel OLM upgrade)..."
approve_installplan_for "${KUEUE_UPGRADE_TO_CSV}"
wait_csv_succeeded "${KUEUE_UPGRADE_TO_CSV}"

# OLM writes status.installedCSV in a separate Subscription sync that can lag the
# CSV phase transition, so poll it rather than reading once.
INSTALLED=""
for _ in $(seq 1 30); do
    INSTALLED=$(oc get subscription "${PACKAGE}" -n "${NS}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
    [[ "${INSTALLED}" == "${KUEUE_UPGRADE_TO_CSV}" ]] && break
    sleep 10
done
if [[ "${INSTALLED}" != "${KUEUE_UPGRADE_TO_CSV}" ]]; then
    echo "ERROR: Subscription installedCSV ${INSTALLED} did not advance to ${KUEUE_UPGRADE_TO_CSV}"
    oc get subscription "${PACKAGE}" -n "${NS}" -o yaml 2>/dev/null || true
    oc get csv -n "${NS}" 2>/dev/null || true
    exit 1
fi
echo "Operator upgraded to ${INSTALLED}."

# OLM replaces the old CSV during the upgrade; best-effort cleanup if it lingers.
oc delete csv "${KUEUE_UPGRADE_FROM_CSV}" -n "${NS}" --ignore-not-found 2>/dev/null || true

oc rollout status deployment/openshift-kueue-operator -n "${NS}" --timeout=10m
oc wait --for=condition=Available deployment/kueue-controller-manager -n "${NS}" --timeout=5m

echo "Verifying CRDs are still present..."
for crd in clusterqueues.kueue.x-k8s.io localqueues.kueue.x-k8s.io \
           resourceflavors.kueue.x-k8s.io workloads.kueue.x-k8s.io; do
    if ! oc get crd "${crd}" &>/dev/null; then
        echo "ERROR: CRD ${crd} missing after operator upgrade"
        exit 1
    fi
done

echo "Cleaning up stale test namespaces from the previous version..."
for ns in $(oc get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E "^kueue-|^e2e-" | grep -v "smoke"); do
    oc delete namespace "$ns" --ignore-not-found 2>/dev/null || true
done

# Re-apply the Kueue CR the e2e suite expects (FairSharing; DRA mappings when the
# DRA APIs are present) so tests find the expected config after the upgrade.
DRA_CONFIG=""
if oc api-resources 2>/dev/null | grep -q "deviceclasses"; then
    echo "DRA APIs available, including deviceClassMappings in CR"
    DRA_CONFIG="    resources:
      deviceClassMappings:
      - name: gpu
        deviceClassNames:
        - gpu.example.com
      - name: gpu-late-dc
        deviceClassNames:
        - gpu-late-dc.example.com"
else
    echo "DRA APIs not available, skipping deviceClassMappings"
fi

cat <<EOF | oc apply -f -
apiVersion: kueue.openshift.io/v1
kind: Kueue
metadata:
  name: cluster
  namespace: ${NS}
spec:
  managementState: Managed
  config:
    preemption:
      preemptionPolicy: FairSharing
${DRA_CONFIG}
    integrations:
      frameworks:
      - BatchJob
      - Pod
      - Deployment
      - StatefulSet
      - JobSet
      - LeaderWorkerSet
EOF

echo "Waiting for controller-manager to stabilize..."
sleep 10
oc wait --for=condition=Available deployment/kueue-controller-manager -n "${NS}" --timeout=5m

echo "Operator z-stream upgrade complete."
oc get csv -n "${NS}"
oc get deployment -n "${NS}" -o wide
