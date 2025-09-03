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

# Install the CNV operator
cat << EOF| oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: cnv-nightly-catalog-source
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: quay.io/openshift-cnv/nightly-catalog:${CNV_VERSION}
  displayName: OpenShift Virtualization Nightly Index
  publisher: Red Hat
  updateStrategy:
    registryPoll:
      interval: 8h
EOF

RETRIES=30
for i in $(seq ${RETRIES}); do
  status=$(oc get catalogsource cnv-nightly-catalog-source -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}') 
  if [[ $status == "READY" ]]; then
    break
  else
    echo "waiting for catalog source to be read, current status: $status"
  fi
  sleep 10
done

STARTING_CSV=$(oc get packagemanifest -l catalog=cnv-nightly-catalog-source -n openshift-marketplace -o jsonpath="{$.items[?(@.metadata.name=='kubevirt-hyperconverged')].status.channels[?(@.name==\"nightly-${CNV_VERSION}\")].currentCSV}")

cat << EOF| oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
    name: openshift-cnv
EOF

cat << EOF| oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
    name: kubevirt-hyperconverged-group
    namespace: openshift-cnv
spec:
    targetNamespaces:
    - openshift-cnv
EOF

cat << EOF| oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
    name: hco-operatorhub
    namespace: openshift-cnv
spec:
    source: cnv-nightly-catalog-source
    sourceNamespace: openshift-marketplace
    name: kubevirt-hyperconverged
    startingCSV: ${STARTING_CSV}
    channel: "nightly-${CNV_VERSION}"
EOF

until oc get csv -n openshift-cnv $STARTING_CSV ; do  sleep 5; done
oc wait --timeout=300s -n openshift-cnv csv $STARTING_CSV --for=jsonpath='{.status.phase}'=Succeeded

cat << EOF| oc apply -f -
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
Spec: {}
EOF

sleep 20

oc wait --timeout=300s -n openshift-cnv csv $STARTING_CSV --for=jsonpath='{.status.phase}'=Succeeded
oc wait hyperconverged -n openshift-cnv kubevirt-hyperconverged --for=condition=Available --timeout=15m

if [ -n "$TUNING_POLICY" ]; then
  oc patch hyperconverged kubevirt-hyperconverged -n openshift-cnv --type=json -p="[{'op': 'add', 'path': '/spec/tuningPolicy', 'value': '$TUNING_POLICY'}]"
fi
