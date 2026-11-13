#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Install the Kueue operator via OLM (OperatorGroup + Subscription) from the
# CatalogSource created by kueue-operator-enable-catalogsource-art, or from the
# released redhat-operators catalog. Waits for the CSV to reach Succeeded and
# surfaces InstallPlan failures.

OO_INSTALL_NAMESPACE=openshift-kueue-operator
PACKAGE=kueue-operator

SOURCE=${KUEUE_OPERATOR_SOURCE}
SOURCE_NAMESPACE=${KUEUE_OPERATOR_SOURCE_NAMESPACE}

oc create namespace "${OO_INSTALL_NAMESPACE}" 2>/dev/null || true
oc label namespace "${OO_INSTALL_NAMESPACE}" openshift.io/cluster-monitoring=true --overwrite

# An OperatorGroup with no spec.targetNamespaces selects all namespaces
# (AllNamespaces install mode).
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${PACKAGE}
  namespace: ${OO_INSTALL_NAMESPACE}
EOF

CHANNEL_SPEC=""
if [ -n "${KUEUE_OPERATOR_CHANNEL}" ]; then
    CHANNEL_SPEC="  channel: ${KUEUE_OPERATOR_CHANNEL}"
fi

SUB=$(
    cat <<EOF | oc apply -f - -o jsonpath='{.metadata.name}'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${PACKAGE}
  namespace: ${OO_INSTALL_NAMESPACE}
spec:
  installPlanApproval: Automatic
  name: ${PACKAGE}
  source: ${SOURCE}
  sourceNamespace: ${SOURCE_NAMESPACE}
${CHANNEL_SPEC}
EOF
)

for _ in {1..90}; do
    CSV=$(oc -n "${OO_INSTALL_NAMESPACE}" get subscription "${SUB}" -o jsonpath='{.status.installedCSV}' || true)
    if [[ -n "${CSV}" ]]; then
        if [[ "$(oc -n "${OO_INSTALL_NAMESPACE}" get csv "${CSV}" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
            echo "ClusterServiceVersion \"${CSV}\" ready"

            # Export the must-gather image pinned in the CSV's relatedImages so
            # the post chain gathers diagnostics with the image matching the
            # tested build (consumed by `make run-must` in the kueue-operator
            # repo; Konflux-based jobs never set it and keep their resolution).
            # The ref is registry.redhat.io/kueue/kueue-must-gather-rhel9@sha256:...
            # and is pulled on-cluster through the stage IDMS applied by
            # kueue-operator-enable-catalogsource-art. Matched by image, not by
            # name: the relatedImages key changed between CSV versions
            # ("must-gather" up to 1.5.0, "kueue-must-gather-rhel9" from 1.5.1).
            MG=$(oc -n "${OO_INSTALL_NAMESPACE}" get csv "${CSV}" -o json \
                | jq -r '.spec.relatedImages[]? | select(.image | test("must-gather")) | .image' \
                | head -1)
            if [[ -n "${MG}" ]]; then
                echo "export KUEUE_MUST_GATHER_IMAGE=${MG}" >> "${SHARED_DIR}/env"
                echo "Exported KUEUE_MUST_GATHER_IMAGE=${MG}"
            else
                echo "WARNING: no must-gather entry in relatedImages of ${CSV}; the post chain will fall back to Konflux resolution" >&2
            fi

            exit 0
        fi
    fi
    STATUS=$(oc -n "${OO_INSTALL_NAMESPACE}" get subscription "${SUB}" -o jsonpath='{.status.conditions[?(@.type=="InstallPlanFailed")].status}' || true)
    if [[ "${STATUS}" == "True" ]]; then
        MESSAGE=$(oc -n "${OO_INSTALL_NAMESPACE}" get subscription "${SUB}" -o jsonpath='{range .status.conditions[?(@.type=="InstallPlanFailed")]}{.type}{" ("}{.reason}{"): "}{.message}{end}')
        echo "kueue-operator: ${MESSAGE}"
        exit 1
    fi
    sleep 10
done
echo "Timed out waiting for CSV to become ready"
exit 1
