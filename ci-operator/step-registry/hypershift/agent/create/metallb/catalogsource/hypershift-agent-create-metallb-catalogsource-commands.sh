#!/bin/bash

set -eoux pipefail

function create_marketplace_namespace () {
    # Since OCP 4.11, the marketplace is optional. If it is not installed, we need to create the namespace manually.
    if ! oc get ns openshift-marketplace; then
        cat <<EOF | oc create -f -
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
    fi
}

function create_metallb_catalogsource() {
    echo "Creating CatalogSource for metallb..."

    local catalog_name="metallb-konflux"
    local version

    version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null | cut -d. -f1-2)
    if [[ -z "${version}" ]]; then
        echo "Could not detect cluster version"
        return 1
    fi

    echo "Detected OpenShift version: $version"

    local index_image
    if [[ "${DISCONNECTED}" == "true" ]]; then
        local mirror_registry_url
        mirror_registry_url=$(cat "${SHARED_DIR}/mirror_registry_url")
        index_image="${mirror_registry_url//5000/6003}/redhat-user-workloads/ocp-art-tenant/art-fbc:ocp__${version}__metallb-rhel9-operator"
    else
        index_image="quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:ocp__${version}__metallb-rhel9-operator"
    fi

    if ! oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${catalog_name}
  namespace: openshift-marketplace
spec:
  displayName: ${catalog_name}
  image: "${index_image}"
  publisher: OpenShift QE
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOF
    then
        echo "CatalogSource apply failed for metallb"
        return 1
    else
        echo "CatalogSource created for metallb"
    fi

    # Wait for catalog ready
    echo "Waiting for CatalogSource to be ready..."
    if ! oc wait --for=jsonpath='{.status.connectionState.lastObservedState}'=READY \
        catalogsource "$catalog_name" -n openshift-marketplace --timeout=300s 2>/dev/null; then
        echo "CatalogSource $catalog_name not ready within timeout"
        return 1
    else
        echo "CatalogSource is ready"
    fi

    return 0
}

if [[ "${KONFLUX_DEPLOY_CATALOG_SOURCE:-false}" == "false" ]]; then
  echo "KONFLUX_DEPLOY_CATALOG_SOURCE is set to false, skipping CatalogSource deployment"
  exit 0
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

if [ ! -f "${SHARED_DIR}/nested_kubeconfig" ]; then
  echo "kubeconfig for nested cluster not found in ${SHARED_DIR}/nested_kubeconfig"
  exit 1
fi

export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"

create_marketplace_namespace
create_metallb_catalogsource