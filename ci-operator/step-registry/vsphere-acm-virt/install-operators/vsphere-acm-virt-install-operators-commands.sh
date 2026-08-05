#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# Source proxy config if present (SHARED_DIR is guaranteed in CI).
[[ -s "${SHARED_DIR}/proxy-conf.sh" ]] && source "${SHARED_DIR}/proxy-conf.sh"

[[ -n "${KUBECONFIG}" ]]
[[ -r "${KUBECONFIG}" ]]

# WaitForCsv — poll Subscription for installedCSV name, then wait for Succeeded.
# The CSV name is not known at install time; derive it from Subscription status.
WaitForCsv() {
    typeset ns="${1:?}"; shift
    typeset subName="${1:?}"; shift

    (
        typeset csvName=''
        typeset -i wInt=10 wMax=300
        SECONDS=0
        while (( SECONDS < wMax )); do
            csvName="$(oc get subscription "${subName}" -n "${ns}" \
                -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
            [[ -n "${csvName}" ]] && break
            : "Waiting for installedCSV (${SECONDS}/${wMax}s)"
            sleep "${wInt}"
        done
        (( SECONDS >= wMax )) && { : "Timed out waiting for installedCSV for ${subName}"; exit 1; }
        oc -n "${ns}" wait "clusterserviceversion/${csvName}" \
            --for=jsonpath='{.status.phase}'=Succeeded --timeout=15m 1>/dev/null
        true
    )
    true
}

# --------------------------------------------------------------------------
# 1. Install CNV (OpenShift Virtualization)
# --------------------------------------------------------------------------
oc create namespace openshift-cnv \
    --dry-run=client -o yaml --save-config | oc apply -f -
oc label namespace openshift-cnv openshift.io/cluster-monitoring=true --overwrite

{
    oc create -f - --dry-run=client -o yaml --save-config
} 0<<'ocEOF' | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
  - openshift-cnv
ocEOF

{
    oc create -f - --dry-run=client -o yaml --save-config
} 0<<ocEOF | oc apply -f -
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
ocEOF

WaitForCsv openshift-cnv kubevirt-hyperconverged

{
    oc create -f - --dry-run=client -o yaml --save-config
} 0<<'ocEOF' | oc apply -f -
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec: {}
ocEOF

oc wait hyperconverged kubevirt-hyperconverged -n openshift-cnv \
    --for=condition=Available --timeout=20m

# --------------------------------------------------------------------------
# 2. Install MTV (Migration Toolkit for Virtualization)
# --------------------------------------------------------------------------
oc create namespace openshift-mtv \
    --dry-run=client -o yaml --save-config | oc apply -f -

{
    oc create -f - --dry-run=client -o yaml --save-config
} 0<<'ocEOF' | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: mtv-operator-group
  namespace: openshift-mtv
spec:
  targetNamespaces:
  - openshift-mtv
ocEOF

{
    oc create -f - --dry-run=client -o yaml --save-config
} 0<<ocEOF | oc apply -f -
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
ocEOF

WaitForCsv openshift-mtv mtv-operator

{
    oc create -f - --dry-run=client -o yaml --save-config
} 0<<'ocEOF' | oc apply -f -
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
ocEOF

oc wait --for=create deployment/forklift-controller \
    -n openshift-mtv --timeout=15m
oc wait deployment/forklift-controller -n openshift-mtv \
    --for=condition=Available --timeout=10m

# --------------------------------------------------------------------------
# Final validation — emit resource state to artifacts
# --------------------------------------------------------------------------
mkdir -p "${ARTIFACT_DIR}"
{
    oc get csv         -n openshift-cnv -o wide
    oc get csv         -n openshift-mtv -o wide
    oc get hyperconverged   -n openshift-cnv -o wide
    oc get forkliftcontroller -n openshift-mtv -o wide
} > "${ARTIFACT_DIR}/operator-install-status.txt" 2>&1 || true

true
