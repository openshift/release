#!/bin/bash
#
# Install MTV (Migration Toolkit for Virtualization / Forklift) on the ACM hub cluster via
# ACM Policy targeting local-cluster.
#
# The hub cluster is represented in ACM as the ManagedCluster "local-cluster", which resides
# in the "default" ManagedClusterSet. By binding that set to the policy namespace and using a
# Placement with a name predicate matching "local-cluster", ACM pushes the MTV Policy exclusively
# to the hub — the same declarative path used for CNV hub installation in p2p-install-cnv-hub.
#
# This step replaces BOTH:
#   - The MTV entry in install-operators (direct OLM Subscription on hub)
#   - p2p-mtv-additional-config (direct oc apply of ForkliftController on hub)
# Both are now managed declaratively through ACM's policy engine.
#
# Run after acm-mch (ACM MultiClusterHub must be Available for policy reconciliation).
#
set -Eeuo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/f63f1f606b1d76f6ef2a3e78b4ec1ad7362d4fac/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

if [[ -n "${SHARED_DIR}" && -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
    [[ $- == *x* ]] && _wasTracing=true || _wasTracing=false
    set +x
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
    [[ "${_wasTracing}" == "true" ]] && set -x
fi

[[ -n "${KUBECONFIG}" ]]
[[ -r "${KUBECONFIG}" ]]

typeset policyNs="${MTV_HUB_POLICY_NAMESPACE}"
typeset installNs="${MTV_HUB_INSTALL_NAMESPACE}"
typeset controllerName="${MTV_HUB_FORKLIFT_CONTROLLER_NAME}"

# DumpDiagnostics — write MTV and ACM policy resources to ARTIFACT_DIR.
DumpDiagnostics() {
    [[ -n "${ARTIFACT_DIR}" ]] || return 0
    typeset diagDir="${ARTIFACT_DIR}/mtv-hub"
    mkdir -p "${diagDir}"

    oc get subscription.operators.coreos.com,csv,forkliftcontroller \
        -n "${installNs}" \
        -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,KIND:.kind \
        > "${diagDir}/mtv-resources.txt" 2>&1 || true

    oc get policy,placement,placementbinding \
        -n "${policyNs}" > "${diagDir}/policy-resources.txt" 2>&1 || true

    oc get events -n "${installNs}" --sort-by='.lastTimestamp' \
        -o custom-columns='LAST:.lastTimestamp,TYPE:.type,REASON:.reason,OBJECT:.involvedObject.kind/.involvedObject.name' \
        > "${diagDir}/mtv-events.txt" 2>&1 || true

    oc get pods -n "${installNs}" -o json \
        | jq -r '[.items[] | {NAME: .metadata.name, READY: (.status.containerStatuses | map(.ready) | map(tostring) | join(",")), STATUS: .status.phase, RESTARTS: (.status.containerStatuses[0].restartCount // 0)}] | .[] | "\(.NAME)\t\(.READY)\t\(.STATUS)\t\(.RESTARTS)"' \
        > "${diagDir}/mtv-pods.txt" 2>&1 || true

    oc get deployment "${controllerName}" -n "${installNs}" -o yaml \
        > "${diagDir}/forklift-controller-deployment.yaml" 2>&1 || true
}

# ResolveStartingCsv — resolve the mtv-operator CSV from the hub PackageManifest.
# When MTV_HUB_INSTALL_MAJOR_MINOR is set, returns the latest patch CSV for that major.minor.
# When unset, returns the channel's currentCSV. Prints empty string on lookup failure.
ResolveStartingCsv() {
    typeset manifestJson
    manifestJson="$(oc get packagemanifest mtv-operator \
        -n openshift-marketplace -o json)" || { echo ""; return 0; }

    if [[ -n "${MTV_HUB_INSTALL_MAJOR_MINOR}" ]]; then
        # MTV CSV names follow pattern: mtv-operator.v2.12.x
        typeset latestVersion csvName
        latestVersion="$(jq -r \
            --arg ch "${MTV_HUB_CHANNEL}" \
            --arg prefix "${MTV_HUB_INSTALL_MAJOR_MINOR}." \
            '.status.channels[] | select(.name == $ch) |
             .entries[] | select(.version | startswith($prefix)) | .version' \
            <<< "${manifestJson}" | sort -V | tail -n1)"
        [[ -n "${latestVersion}" ]] || {
            : "No version for MTV ${MTV_HUB_INSTALL_MAJOR_MINOR} in channel ${MTV_HUB_CHANNEL} — falling back to channel head"
            return 0
        }
        csvName="$(jq -r \
            --arg ch "${MTV_HUB_CHANNEL}" \
            --arg ver "${latestVersion}" \
            '.status.channels[] | select(.name == $ch) |
             .entries[] | select(.version == $ver) | .name' \
            <<< "${manifestJson}" | head -n1)"
        [[ -n "${csvName}" ]] || {
            : "No CSV name for MTV version ${latestVersion} in channel ${MTV_HUB_CHANNEL}"
            return 0
        }
        printf '%s' "${csvName}"
    else
        jq -r \
            --arg ch "${MTV_HUB_CHANNEL}" \
            '.status.channels[] | select(.name == $ch) | .currentCSV' \
            <<< "${manifestJson}" | head -n1
    fi
}

# WaitForForkliftController — wait for forklift-controller Deployment Available and
# verify FEATURE_OCP_LIVE_MIGRATION=true (required for CCLM) on the deployment.
WaitForForkliftController() {
    : "Waiting for forklift-controller deployment to be created (timeout=${MTV_HUB_CONTROLLER_CREATE_WAIT_TIMEOUT})"
    oc wait "deployment/${controllerName}" -n "${installNs}" \
        --for=create \
        --timeout="${MTV_HUB_CONTROLLER_CREATE_WAIT_TIMEOUT}" 1>/dev/null

    : "Waiting for forklift-controller deployment Available (timeout=${MTV_HUB_WAIT_TIMEOUT})"
    oc wait "deployment/${controllerName}" -n "${installNs}" \
        --for=condition=Available \
        --timeout="${MTV_HUB_WAIT_TIMEOUT}" 1>/dev/null

    # Verify FEATURE_OCP_LIVE_MIGRATION=true is active on the forklift-controller deployment.
    # This env var is set by the ForkliftController operator when feature_ocp_live_migration=true.
    typeset -i envWaitSecs=0
    typeset -i envWaitMax
    envWaitMax="$(python3 -c "import re; m=re.match(r'(\d+)m', '${MTV_HUB_ENV_WAIT_TIMEOUT}'); print(int(m.group(1))*60) if m else print(600)")" || envWaitMax=600

    while (( envWaitSecs < envWaitMax )); do
        if oc get "deployment/${controllerName}" -n "${installNs}" -o json \
                | jq -e '.spec.template.spec.containers[] | .env[]? | select(.name=="FEATURE_OCP_LIVE_MIGRATION" and .value=="true")' \
                > /dev/null 2>&1; then
            : "FEATURE_OCP_LIVE_MIGRATION=true confirmed on forklift-controller"
            return 0
        fi
        : "Waiting for FEATURE_OCP_LIVE_MIGRATION=true on forklift-controller (${envWaitSecs}/${envWaitMax}s)"
        sleep 15
        (( envWaitSecs += 15 ))
    done

    : "ERROR: FEATURE_OCP_LIVE_MIGRATION was not set to true on forklift-controller within ${MTV_HUB_ENV_WAIT_TIMEOUT}"
    oc get "deployment/${controllerName}" -n "${installNs}" -o json \
        | jq '.spec.template.spec.containers[].env // []' || true
    return 1
}

# --- Main ---

trap DumpDiagnostics ERR

# Resolve optional version-pinned startingCSV.
typeset startingCsv=""
startingCsv="$(ResolveStartingCsv)"
typeset startingCsvLine=""
[[ -z "${startingCsv}" ]] || startingCsvLine="                  startingCSV: ${startingCsv}"
: "MTV hub startingCSV resolved: '${startingCsv}' (channel=${MTV_HUB_CHANNEL})"

# Policy namespace for ACM resources.
oc create namespace "${policyNs}" --dry-run=client -o yaml | oc apply -f -

# Bind the "default" ManagedClusterSet to the policy namespace.
# local-cluster lives in the "default" ManagedClusterSet by default in ACM.
oc create -f - --dry-run=client -o yaml --save-config <<EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: default
  namespace: ${policyNs}
spec:
  clusterSet: default
EOF

# Apply Policy with two ConfigurationPolicy templates:
#   1. mtv-hub-olm-subscription — enforces Namespace + OperatorGroup + Subscription on hub.
#   2. mtv-hub-forklift-controller — enforces ForkliftController with CCLM feature gate.
# Placement targets local-cluster by name predicate within the default ClusterSet.
oc create -f - --dry-run=client -o yaml --save-config <<EOF | oc apply -f -
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: install-mtv-hub
  namespace: ${policyNs}
  annotations:
    policy.open-cluster-management.io/categories: ""
    policy.open-cluster-management.io/standards: ""
    policy.open-cluster-management.io/controls: ""
spec:
  disabled: false
  remediationAction: enforce
  policy-templates:
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: mtv-hub-olm-subscription
        spec:
          remediationAction: enforce
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: v1
                kind: Namespace
                metadata:
                  name: ${installNs}
            - complianceType: musthave
              objectDefinition:
                apiVersion: operators.coreos.com/v1
                kind: OperatorGroup
                metadata:
                  name: openshift-mtv-operatorgroup
                  namespace: ${installNs}
                spec:
                  targetNamespaces:
                    - ${installNs}
            - complianceType: musthave
              objectDefinition:
                apiVersion: operators.coreos.com/v1alpha1
                kind: Subscription
                metadata:
                  name: mtv-operator
                  namespace: ${installNs}
                spec:
                  channel: ${MTV_HUB_CHANNEL}
                  installPlanApproval: Automatic
                  name: mtv-operator
                  source: ${MTV_HUB_SOURCE}
                  sourceNamespace: ${MTV_HUB_SOURCE_NAMESPACE}
${startingCsvLine}
          severity: critical
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: mtv-hub-forklift-controller
        spec:
          remediationAction: enforce
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: forklift.konveyor.io/v1beta1
                kind: ForkliftController
                metadata:
                  name: ${controllerName}
                  namespace: ${installNs}
                spec:
                  olm_managed: "${MTV_HUB_OLM_MANAGED}"
                  feature_ui_plugin: "true"
                  feature_validation: "true"
                  feature_volume_populator: "true"
                  feature_ocp_live_migration: "${MTV_HUB_FEATURE_OCP_LIVE_MIGRATION}"
          severity: critical
---
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: install-mtv-hub-placement
  namespace: ${policyNs}
spec:
  tolerations:
    - key: cluster.open-cluster-management.io/unreachable
      operator: Exists
    - key: cluster.open-cluster-management.io/unavailable
      operator: Exists
  clusterSets:
    - default
  predicates:
    - requiredClusterSelector:
        labelSelector:
          matchExpressions:
            - key: name
              operator: In
              values:
                - local-cluster
---
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: install-mtv-hub-placement
  namespace: ${policyNs}
placementRef:
  name: install-mtv-hub-placement
  apiGroup: cluster.open-cluster-management.io
  kind: Placement
subjects:
  - name: install-mtv-hub
    apiGroup: policy.open-cluster-management.io
    kind: Policy
EOF

WaitForForkliftController

if [[ -n "${ARTIFACT_DIR}" ]]; then
    mkdir -p "${ARTIFACT_DIR}/mtv-hub"
    oc get forkliftcontroller "${controllerName}" -n "${installNs}" -o yaml \
        > "${ARTIFACT_DIR}/mtv-hub/forklift-controller.yaml" || true
    oc get deployment "${controllerName}" -n "${installNs}" \
        -o jsonpath='{.spec.template.spec.containers[].env}' \
        > "${ARTIFACT_DIR}/mtv-hub/forklift-controller-env.txt" || true
    oc get policy,placement,placementbinding -n "${policyNs}" \
        > "${ARTIFACT_DIR}/mtv-hub/acm-policy-resources.txt" || true
fi

: "MTV installation on hub via ACM Policy completed: ForkliftController Available, FEATURE_OCP_LIVE_MIGRATION=true"
true
