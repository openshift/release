#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Install the PREVIOUS z-stream of the Kueue operator from the ART FBC catalog via
# a real OLM Subscription, then create the default Kueue CR. The Subscription is
# pinned to startingCSV=${KUEUE_UPGRADE_FROM_CSV} with Manual InstallPlan approval
# so the upgrade to the channel head is a distinct, observable step
# (kueue-operator-test-upgrade-operator-art). No operator-sdk.

NS=openshift-kueue-operator
PACKAGE=kueue-operator
SOURCE="${KUEUE_OPERATOR_SOURCE}"
SOURCE_NAMESPACE="${KUEUE_OPERATOR_SOURCE_NAMESPACE}"
CHANNEL="${KUEUE_OPERATOR_CHANNEL}"

source "${SHARED_DIR}/env"
: "${KUEUE_UPGRADE_FROM_CSV:?the resolve step did not provide KUEUE_UPGRADE_FROM_CSV}"

echo "Installing previous z-stream ${KUEUE_UPGRADE_FROM_CSV} from ${SOURCE} (channel ${CHANNEL})..."

oc create namespace "${NS}" 2>/dev/null || true
oc label namespace "${NS}" openshift.io/cluster-monitoring=true --overwrite

# An OperatorGroup with no spec.targetNamespaces selects all namespaces.
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${PACKAGE}
  namespace: ${NS}
EOF

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${PACKAGE}
  namespace: ${NS}
spec:
  channel: ${CHANNEL}
  name: ${PACKAGE}
  source: ${SOURCE}
  sourceNamespace: ${SOURCE_NAMESPACE}
  installPlanApproval: Manual
  startingCSV: ${KUEUE_UPGRADE_FROM_CSV}
EOF

# With Manual approval OLM creates an unapproved InstallPlan for the startingCSV.
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
# bounded poll is used instead; an absent CSV yields an empty phase and keeps
# waiting, while a created-but-unsuccessful CSV never passes.
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

approve_installplan_for "${KUEUE_UPGRADE_FROM_CSV}"
wait_csv_succeeded "${KUEUE_UPGRADE_FROM_CSV}"
oc wait --for=condition=Available deployment -n "${NS}" --all --timeout=5m

echo "Creating default Kueue CR..."
oc apply -f - <<EOF
apiVersion: kueue.openshift.io/v1
kind: Kueue
metadata:
  name: cluster
  namespace: ${NS}
spec:
  managementState: Managed
  config:
    integrations:
      frameworks:
      - BatchJob
      - Pod
      - Deployment
      - StatefulSet
      - JobSet
      - LeaderWorkerSet
EOF

echo "Waiting for kueue CRDs..."
for crd in clusterqueues.kueue.x-k8s.io localqueues.kueue.x-k8s.io resourceflavors.kueue.x-k8s.io workloads.kueue.x-k8s.io; do
    for _ in $(seq 1 30); do
        oc get crd "${crd}" &>/dev/null && break
        sleep 10
    done
    if ! oc get crd "${crd}" &>/dev/null; then
        echo "ERROR: CRD ${crd} not available"
        oc get kueue cluster -n "${NS}" -o yaml 2>/dev/null || true
        oc logs -n "${NS}" deployment/openshift-kueue-operator --tail=30 2>/dev/null || true
        exit 1
    fi
done

echo "Previous z-stream ${KUEUE_UPGRADE_FROM_CSV} installed."
oc get csv -n "${NS}"
