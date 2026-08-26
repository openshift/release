#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

oc config view
oc projects

NMSTATE_NS="openshift-nmstate"
NMSTATE_PACKAGE="kubernetes-nmstate-operator"
CATALOG_NAME="art-operators-nightly-catalog-source"

if oc get nmstate nmstate -n "${NMSTATE_NS}" >/dev/null 2>&1; then
  echo "NMState is already installed"
  oc get csv -n "${NMSTATE_NS}"
  oc get pods -n "${NMSTATE_NS}"
  exit 0
fi

BREW_DOCKERCONFIGJSON="${BREW_DOCKERCONFIGJSON:-/var/run/brew-pullsecret/.dockerconfigjson}"
if [ ! -f "${BREW_DOCKERCONFIGJSON}" ]; then
  echo "ERROR: Brew pull secret not found at ${BREW_DOCKERCONFIGJSON}"
  exit 1
fi

# Merge brew.registry.redhat.io into the existing cluster pull secret.
# Do not replace the secret; BM already needs payload/CNV auths.
# Disable tracing due to pull-secret handling.
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
oc get secret pull-secret -n openshift-config -o json \
  | jq -r '.data[".dockerconfigjson"]' | base64 -d > /tmp/existing_pull_secret.json
jq -s '.[0] * .[1]' /tmp/existing_pull_secret.json "${BREW_DOCKERCONFIGJSON}" \
  > /tmp/merged_pull_secret.json
oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/merged_pull_secret.json
rm -f /tmp/existing_pull_secret.json /tmp/merged_pull_secret.json
$WAS_TRACING && set -x

echo "Allowing insecure registry-proxy.engineering.redhat.com and applying brew ICSP"
oc patch image.config.openshift.io/cluster --type merge \
  -p '{"spec":{"registrySources":{"insecureRegistries":["registry-proxy.engineering.redhat.com"]}}}'

cat << EOF | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: brew-registry
spec:
  repositoryDigestMirrors:
  - mirrors:
    - brew.registry.redhat.io
    source: registry.redhat.io
  - mirrors:
    - brew.registry.redhat.io
    source: registry.stage.redhat.io
  - mirrors:
    - brew.registry.redhat.io
    source: registry-proxy.engineering.redhat.com
EOF

echo "Waiting for cluster to stabilize after pull-secret and ICSP updates"
oc adm wait-for-stable-cluster --minimum-stable-period=2m --timeout=40m

# Nightly 5.x payloads do not publish iib-int-index-art-operators-5.0.
# Use the ART operator index for the compatible OCP stream (4.22 for 5.0).
# This is not quay.io/openshift-release-dev/ocp-release:4.22 (that is a
# cluster payload, not a catalog).
if [ -z "${NMSTATE_CATALOG_IMAGE}" ]; then
  NMSTATE_CATALOG_IMAGE="quay.io/openshift-release-dev/ocp-release-nightly:iib-int-index-art-operators-${NMSTATE_CATALOG_VERSION}"
fi
echo "Using NMState catalog image ${NMSTATE_CATALOG_IMAGE}"

cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATALOG_NAME}
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: ${NMSTATE_CATALOG_IMAGE}
  displayName: ART Operators Nightly Index
  publisher: Red Hat
  updateStrategy:
    registryPoll:
      interval: 8h
EOF

if ! oc wait --for=jsonpath='{.status.connectionState.lastObservedState}'=READY \
  catalogsource/"${CATALOG_NAME}" -n openshift-marketplace --timeout=10m; then
  echo "CatalogSource ${CATALOG_NAME} did not become READY"
  oc get catalogsource "${CATALOG_NAME}" -n openshift-marketplace -o yaml || true
  oc get pods -n openshift-marketplace || true
  oc describe pods -n openshift-marketplace -l olm.catalogSource="${CATALOG_NAME}" || true
  exit 1
fi

STARTING_CSV=$(oc get packagemanifest -l catalog="${CATALOG_NAME}" -n openshift-marketplace -o jsonpath="{$.items[?(@.metadata.name=='${NMSTATE_PACKAGE}')].status.channels[?(@.name==\"${NMSTATE_CHANNEL}\")].currentCSV}")
if [ -z "${STARTING_CSV}" ]; then
  echo "Failed to resolve currentCSV for ${NMSTATE_PACKAGE} channel ${NMSTATE_CHANNEL} from ${CATALOG_NAME}"
  oc get packagemanifest -l catalog="${CATALOG_NAME}" -n openshift-marketplace
  oc get packagemanifest "${NMSTATE_PACKAGE}" -n openshift-marketplace -o yaml || true
  exit 1
fi
echo "Installing ${NMSTATE_PACKAGE} startingCSV=${STARTING_CSV}"

cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${NMSTATE_NS}
  labels:
    name: ${NMSTATE_NS}
    openshift.io/cluster-monitoring: "true"
EOF

cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${NMSTATE_NS}
  namespace: ${NMSTATE_NS}
spec:
  targetNamespaces:
  - ${NMSTATE_NS}
EOF

cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${NMSTATE_PACKAGE}
  namespace: ${NMSTATE_NS}
spec:
  channel: ${NMSTATE_CHANNEL}
  installPlanApproval: Automatic
  name: ${NMSTATE_PACKAGE}
  source: ${CATALOG_NAME}
  sourceNamespace: openshift-marketplace
  startingCSV: ${STARTING_CSV}
EOF

until oc get csv -n "${NMSTATE_NS}" "${STARTING_CSV}" >/dev/null 2>&1; do
  echo "Waiting for CSV ${STARTING_CSV}"
  sleep 5
done
oc wait --timeout=10m -n "${NMSTATE_NS}" csv "${STARTING_CSV}" --for=jsonpath='{.status.phase}'=Succeeded

until oc get crd nmstates.nmstate.io >/dev/null 2>&1; do
  echo "Waiting for NMState CRD"
  sleep 5
done

cat << EOF | oc apply -f -
apiVersion: nmstate.io/v1
kind: NMState
metadata:
  name: nmstate
  namespace: ${NMSTATE_NS}
EOF

until oc get ds -n "${NMSTATE_NS}" nmstate-handler >/dev/null 2>&1; do
  echo "Waiting for nmstate-handler DaemonSet"
  sleep 5
done
oc rollout status ds/nmstate-handler -n "${NMSTATE_NS}" --timeout=10m
oc get pods -n "${NMSTATE_NS}"
