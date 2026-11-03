#!/bin/bash

set -euo pipefail
shopt -s inherit_errexit

# Create a CatalogSource serving the GA (released) redhat-operators index of a
# given OCP version, so operators that are not published yet in the current
# dev/nightly index can still be installed via OLM.

if [[ -z "${GA_INDEX_OCP_VERSION:-}" ]]; then
    echo "ERROR: GA_INDEX_OCP_VERSION must be set (e.g. 4.22)"
    exit 1
fi

INDEX_IMAGE="registry.redhat.io/redhat/redhat-operator-index:v${GA_INDEX_OCP_VERSION}"
CATALOGSOURCE_NAME="${CATALOGSOURCE_NAME:-redhat-operators-v${GA_INDEX_OCP_VERSION//./}}"

# Set the cluster proxy configuration, if it is present.
if test -s "${SHARED_DIR}/proxy-conf.sh"; then
    echo "setting the proxy"
    source "${SHARED_DIR}/proxy-conf.sh"
else
    echo "no proxy setting."
fi

# openshift-marketplace is the OLM global namespace. Since OCP 4.11 the
# marketplace is optional, so create the namespace if it is missing.
if ! oc get namespace openshift-marketplace >/dev/null 2>&1; then
    echo "creating the openshift-marketplace namespace"
    oc create namespace openshift-marketplace
fi

echo "Creating CatalogSource ${CATALOGSOURCE_NAME} serving ${INDEX_IMAGE}"
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATALOGSOURCE_NAME}
  namespace: openshift-marketplace
spec:
  displayName: ${CATALOGSOURCE_NAME}
  sourceType: grpc
  image: ${INDEX_IMAGE}
  publisher: OpenShift CI
  updateStrategy:
    registryPoll:
      interval: 10m
  grpcPodConfig:
    securityContextConfig: restricted
    extractContent:
      cacheDir: /tmp/cache
      catalogDir: /configs
    memoryTarget: 30Mi
EOF

echo "Waiting for CatalogSource ${CATALOGSOURCE_NAME} to become READY"
for i in $(seq 1 40); do
    STATUS=$(oc -n openshift-marketplace get catalogsource "${CATALOGSOURCE_NAME}" \
        -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)
    if [[ "${STATUS}" == "READY" ]]; then
        echo "${CATALOGSOURCE_NAME} is READY"
        echo "Sample of packagemanifests served by ${CATALOGSOURCE_NAME}:"
        oc get packagemanifest -l catalog="${CATALOGSOURCE_NAME}" \
            -o custom-columns=NAME:.metadata.name,DEFAULT_CHANNEL:.status.defaultChannel --no-headers | head -15 || true
        exit 0
    fi
    echo "attempt ${i}/40: ${CATALOGSOURCE_NAME} not ready yet (status: ${STATUS:-unknown}), retrying in 15s"
    sleep 15
done

echo "ERROR: ${CATALOGSOURCE_NAME} did not become READY"
oc -n openshift-marketplace get catalogsource "${CATALOGSOURCE_NAME}" -o yaml || true
oc -n openshift-marketplace get pods -o wide || true
oc -n openshift-marketplace describe pods -l olm.catalogSource="${CATALOGSOURCE_NAME}" || true
exit 1
