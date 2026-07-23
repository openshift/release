#!/bin/bash
set -euo pipefail

function run_command() {
    echo "Running Command: $*"
    "$@"
}

function check_olm_capability(){
    knownCaps=$(oc get clusterversion version -o=jsonpath="{.status.capabilities.knownCapabilities}")
    if [[ ${knownCaps} =~ "OperatorLifecycleManager" ]]; then
        echo "knownCapabilities contains OperatorLifecycleManager"
        enabledCaps=$(oc get clusterversion version -o=jsonpath="{.status.capabilities.enabledCapabilities}")
        if [[ ! ${enabledCaps} =~ "OperatorLifecycleManager" ]]; then
            echo "OperatorLifecycleManager capability is not enabled, skip..."
            return 1
        fi
    fi
    return 0
}

function check_marketplace() {
    ret=0
    run_command oc get ns openshift-marketplace || ret=$?
    if [[ $ret -eq 0 ]]; then
        echo "openshift-marketplace project AlreadyExists, skip creating."
        return 0
    fi

    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  labels:
    security.openshift.io/scc.podSecurityLabelSync: "false"
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/warn: baseline
  name: openshift-marketplace
EOF
}

run_command oc whoami
run_command oc version -o yaml

ocp_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d '.' -f1,2)
echo "Detected OCP version: ${ocp_version}"

if [[ -z "${OO_INDEX}" ]]; then
    index_image="registry.redhat.io/redhat/redhat-operator-index:v${ocp_version}"
else
    index_image="${OO_INDEX}"
fi
echo "Using operator index image: ${index_image}"

CI_AUTH_PATH="/var/run/secrets/ci-pull-credentials/.dockerconfigjson"
if [[ -f "${CI_AUTH_PATH}" ]]; then
    echo "Injecting registry.redhat.io credentials into cluster global pull secret..."

    # Disable tracing due to credential handling
    [[ "${-}" == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
    set +x

    CLUSTER_PS_ORIG="/tmp/cluster-pull-secret.json.orig"
    CLUSTER_PS_UPDATED="/tmp/cluster-pull-secret.json.updated"

    oc get secret/pull-secret -n openshift-config \
        --template='{{index .data ".dockerconfigjson" | base64decode}}' > "${CLUSTER_PS_ORIG}"

    REDHAT_AUTH=$(jq -r '.auths."registry.redhat.io"' "${CI_AUTH_PATH}")
    if [[ "${REDHAT_AUTH}" != "null" ]]; then
        echo "${REDHAT_AUTH}" | jq '{ "auths": { "registry.redhat.io": . } }' > /tmp/redhat-auth-fragment.json
        jq -s '.[0] * .[1]' "${CLUSTER_PS_ORIG}" /tmp/redhat-auth-fragment.json > "${CLUSTER_PS_UPDATED}"
        oc set data secret/pull-secret -n openshift-config \
            --from-file=.dockerconfigjson="${CLUSTER_PS_UPDATED}"
        echo "registry.redhat.io credentials merged into cluster pull secret."
    else
        echo "WARNING: registry.redhat.io entry not found in CI credentials, skipping pull secret update."
    fi

    rm -f "${CLUSTER_PS_ORIG}" "${CLUSTER_PS_UPDATED}" /tmp/redhat-auth-fragment.json
    ${WAS_TRACING} && set -x
else
    echo "WARNING: CI pull credentials not found at ${CI_AUTH_PATH}, skipping pull secret update."
fi

check_olm_capability || exit 0
check_marketplace

if [[ "${DISCONNECTED}" == "true" ]]; then
    echo "Disconnected cluster: disabling default CatalogSources..."
    run_command oc patch operatorhub cluster -p '{"spec": {"disableAllDefaultSources": true}}' --type=merge

    ocp_major=$(echo "${ocp_version}" | cut -d '.' -f1)
    ocp_minor=$(echo "${ocp_version}" | cut -d '.' -f2)
    if [[ "X${ocp_major}" == "X4" && -n "${ocp_minor}" && "${ocp_minor}" -gt 17 ]]; then
        echo "Disabling OLMv1 default ClusterCatalogs..."
        run_command oc patch clustercatalog openshift-certified-operators -p '{"spec": {"availabilityMode": "Unavailable"}}' --type=merge || true
        run_command oc patch clustercatalog openshift-redhat-operators -p '{"spec": {"availabilityMode": "Unavailable"}}' --type=merge || true
        run_command oc patch clustercatalog openshift-redhat-marketplace -p '{"spec": {"availabilityMode": "Unavailable"}}' --type=merge || true
        run_command oc patch clustercatalog openshift-community-operators -p '{"spec": {"availabilityMode": "Unavailable"}}' --type=merge || true
        run_command oc get clustercatalog
    fi
else
    echo "Connected cluster: keeping default CatalogSources, adding ${CATALOGSOURCE_NAME} with full upstream index."
fi

echo "Creating CatalogSource: ${CATALOGSOURCE_NAME}"
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATALOGSOURCE_NAME}
  namespace: openshift-marketplace
spec:
  displayName: Red Hat Operators (Full Index)
  image: ${index_image}
  publisher: Red Hat
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOF

echo "Waiting for CatalogSource ${CATALOGSOURCE_NAME} to become READY..."
COUNTER=0
while [ $COUNTER -lt 600 ]; do
    sleep 20
    COUNTER=$((COUNTER + 20))
    echo "Waiting ${COUNTER}s..."
    STATUS=$(oc -n openshift-marketplace get catalogsource "${CATALOGSOURCE_NAME}" -o=jsonpath="{.status.connectionState.lastObservedState}" 2>/dev/null || echo "")
    if [[ "${STATUS}" == "READY" ]]; then
        echo "CatalogSource ${CATALOGSOURCE_NAME} is READY"
        break
    fi
done

if [[ "${STATUS}" != "READY" ]]; then
    echo "ERROR: CatalogSource ${CATALOGSOURCE_NAME} did not become READY within timeout"
    run_command oc get pods -o wide -n openshift-marketplace
    run_command oc -n openshift-marketplace get catalogsource "${CATALOGSOURCE_NAME}" -o yaml
    run_command oc -n openshift-marketplace get pods -l "olm.catalogSource=${CATALOGSOURCE_NAME}" -o yaml
    exit 1
fi
