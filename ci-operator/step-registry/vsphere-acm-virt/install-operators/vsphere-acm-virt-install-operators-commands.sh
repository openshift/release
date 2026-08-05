#!/bin/bash
#
# Install CNV (OpenShift Virtualization) and MTV (Migration Toolkit for Virtualization)
# operators on the target OCP cluster via OLM.
#
set -euxo pipefail

if [[ -n "${SHARED_DIR:-}" && -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

[[ -n "${KUBECONFIG}" ]]
[[ -r "${KUBECONFIG}" ]]

# WaitForCsv — poll until a CSV in the given namespace reaches Succeeded.
WaitForCsv() {
    local ns="${1:?}" package="${2:?}"
    local -i deadline=$(( SECONDS + 1200 ))  # 20 min
    local csv phase

    while (( SECONDS < deadline )); do
        csv="$(oc get csv -n "${ns}" -o jsonpath="{.items[?(@.spec.displayName)].metadata.name}" 2>/dev/null \
            | tr ' ' '\n' | grep "^${package}" | head -1 || true)"
        if [[ -z "${csv}" ]]; then
            csv="$(oc get subscription -n "${ns}" -o jsonpath='{.items[0].status.installedCSV}' 2>/dev/null || true)"
        fi
        if [[ -n "${csv}" ]]; then
            phase="$(oc get csv "${csv}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
            if [[ "${phase}" == "Succeeded" ]]; then
                echo "CSV ${csv} reached Succeeded"
                return 0
            fi
            echo "CSV ${csv} phase: ${phase:-pending} (waiting...)"
        else
            echo "No CSV found yet for ${package} in ${ns} (waiting...)"
        fi
        sleep 15
    done
    echo "ERROR: CSV for ${package} did not reach Succeeded within timeout" >&2
    oc get csv -n "${ns}" -o wide 2>&1 || true
    return 1
}

# --------------------------------------------------------------------------
# 1. Install CNV (OpenShift Virtualization)
# --------------------------------------------------------------------------
echo "=== Installing CNV operator ==="

oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cnv
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
  - openshift-cnv
EOF

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  channel: "${CNV_CHANNEL}"
  installPlanApproval: Automatic
  name: kubevirt-hyperconverged
  source: "${CNV_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF

WaitForCsv openshift-cnv kubevirt-hyperconverged

echo "=== Creating HyperConverged CR ==="
oc apply -f - <<'EOF'
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec: {}
EOF

# Wait for HyperConverged to report Available
oc wait hyperconverged kubevirt-hyperconverged -n openshift-cnv \
    --for=condition=Available --timeout=20m

echo "CNV operator installed and HyperConverged is Available"

# --------------------------------------------------------------------------
# 2. Install MTV (Migration Toolkit for Virtualization)
# --------------------------------------------------------------------------
echo "=== Installing MTV operator ==="

oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-mtv
EOF

oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: mtv-operator-group
  namespace: openshift-mtv
spec:
  targetNamespaces:
  - openshift-mtv
EOF

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: mtv-operator
  namespace: openshift-mtv
spec:
  channel: "${MTV_CHANNEL}"
  installPlanApproval: Automatic
  name: mtv-operator
  source: "${MTV_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF

WaitForCsv openshift-mtv mtv-operator

echo "=== Creating ForkliftController CR ==="
oc apply -f - <<'EOF'
apiVersion: forklift.konveyor.io/v1beta1
kind: ForkliftController
metadata:
  name: forklift-controller
  namespace: openshift-mtv
spec:
  olm_managed: true
  feature_ui_plugin: "true"
  feature_validation: "true"
  feature_volume_populator: "true"
EOF

# Wait for the forklift-controller deployment to become Available.
if ! oc wait --for=create deployment/forklift-controller \
        -n openshift-mtv --timeout=10m 2>/dev/null; then
    echo "Waiting for forklift-controller deployment to be created..."
    sleep 30
    oc wait --for=create deployment/forklift-controller \
        -n openshift-mtv --timeout=5m
fi

oc wait deployment/forklift-controller -n openshift-mtv \
    --for=condition=Available --timeout=10m

echo "MTV operator installed and ForkliftController is Available"

# --------------------------------------------------------------------------
# 3. Final validation
# --------------------------------------------------------------------------
echo "=== Final validation ==="
oc get csv -n openshift-cnv -o wide
oc get csv -n openshift-mtv -o wide
oc get hyperconverged -n openshift-cnv -o wide
oc get forkliftcontroller -n openshift-mtv -o wide

echo "Both CNV and MTV operators are installed and healthy"
