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

CNV_NS="openshift-cnv"
CNV_CATALOG="cnv-nightly-catalog-source"
CNV_CHANNEL="nightly-${CNV_VERSION}"
WAIT_TIMEOUT_SEC=600

dump_cnv_catalog() {
  echo "=== CNV catalog diagnostics ==="
  oc get catalogsource "${CNV_CATALOG}" -n openshift-marketplace -o yaml || true
  oc get pods -n openshift-marketplace -o wide || true
  oc describe pods -n openshift-marketplace -l "olm.catalogSource=${CNV_CATALOG}" || true
  oc get packagemanifest -l "catalog=${CNV_CATALOG}" -n openshift-marketplace || true
  oc get packagemanifest kubevirt-hyperconverged -n openshift-marketplace -o yaml || true
  oc get events -n openshift-marketplace --sort-by='.lastTimestamp' | tail -80 || true
}

dump_cnv_olm() {
  echo "=== CNV OLM diagnostics ==="
  oc get subscription,installplan,csv -n "${CNV_NS}" || true
  oc get events -n "${CNV_NS}" --sort-by='.lastTimestamp' | tail -80 || true
}

get_starting_csv() {
  oc get packagemanifest -l "catalog=${CNV_CATALOG}" -n openshift-marketplace -o jsonpath="{$.items[?(@.metadata.name=='kubevirt-hyperconverged')].status.channels[?(@.name==\"${CNV_CHANNEL}\")].currentCSV}" 2>/dev/null || true
}

CNV_AVAILABLE=$(oc get hyperconverged -n "${CNV_NS}" kubevirt-hyperconverged -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
if [ "$CNV_AVAILABLE" != "True" ]; then
  # Install the CNV operator
  cat << EOF| oc apply -f -
  apiVersion: operators.coreos.com/v1alpha1
  kind: CatalogSource
  metadata:
    name: ${CNV_CATALOG}
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

  echo "Waiting for CatalogSource ${CNV_CATALOG} to become READY"
  if ! oc wait --for=jsonpath='{.status.connectionState.lastObservedState}'=READY catalogsource/"${CNV_CATALOG}" -n openshift-marketplace --timeout="${WAIT_TIMEOUT_SEC}s"; then
    echo "CatalogSource ${CNV_CATALOG} did not become READY"
    dump_cnv_catalog
    exit 1
  fi

  elapsed=0
  STARTING_CSV="$(get_starting_csv)"
  until [ -n "${STARTING_CSV}" ]; do
    if [ "${elapsed}" -ge "${WAIT_TIMEOUT_SEC}" ]; then
      echo "Timed out waiting for kubevirt-hyperconverged currentCSV on channel ${CNV_CHANNEL}"
      dump_cnv_catalog
      exit 1
    fi
    echo "Waiting for packagemanifest kubevirt-hyperconverged channel ${CNV_CHANNEL} (${elapsed}s/${WAIT_TIMEOUT_SEC}s)"
    sleep 10
    elapsed=$((elapsed + 10))
    STARTING_CSV="$(get_starting_csv)"
  done
  echo "Using startingCSV ${STARTING_CSV} from channel ${CNV_CHANNEL}"

  cat << EOF| oc apply -f -
  apiVersion: v1
  kind: Namespace
  metadata:
      name: ${CNV_NS}
EOF

  cat << EOF| oc apply -f -
  apiVersion: operators.coreos.com/v1
  kind: OperatorGroup
  metadata:
      name: kubevirt-hyperconverged-group
      namespace: ${CNV_NS}
  spec:
      targetNamespaces:
      - ${CNV_NS}
EOF

  cat << EOF| oc apply -f -
  apiVersion: operators.coreos.com/v1alpha1
  kind: Subscription
  metadata:
      name: hco-operatorhub
      namespace: ${CNV_NS}
  spec:
      source: ${CNV_CATALOG}
      sourceNamespace: openshift-marketplace
      name: kubevirt-hyperconverged
      startingCSV: ${STARTING_CSV}
      channel: "${CNV_CHANNEL}"
EOF

  elapsed=0
  until oc get csv -n "${CNV_NS}" "${STARTING_CSV}" >/dev/null 2>&1; do
    if [ "${elapsed}" -ge "${WAIT_TIMEOUT_SEC}" ]; then
      echo "Timed out waiting for CSV ${STARTING_CSV}"
      dump_cnv_catalog
      dump_cnv_olm
      exit 1
    fi
    echo "Waiting for CSV ${STARTING_CSV} (${elapsed}s/${WAIT_TIMEOUT_SEC}s)"
    sleep 10
    elapsed=$((elapsed + 10))
  done
  if ! oc wait --timeout=300s -n "${CNV_NS}" csv "${STARTING_CSV}" --for=jsonpath='{.status.phase}'=Succeeded; then
    echo "CSV ${STARTING_CSV} did not reach Succeeded"
    dump_cnv_olm
    exit 1
  fi

  cat << EOF| oc apply -f -
  apiVersion: hco.kubevirt.io/v1beta1
  kind: HyperConverged
  metadata:
    name: kubevirt-hyperconverged
    namespace: ${CNV_NS}
  spec: {}
EOF

  sleep 20

  if ! oc wait --timeout=300s -n "${CNV_NS}" csv "${STARTING_CSV}" --for=jsonpath='{.status.phase}'=Succeeded; then
    echo "CSV ${STARTING_CSV} did not stay Succeeded after HyperConverged create"
    dump_cnv_olm
    exit 1
  fi
  if ! oc wait hyperconverged -n "${CNV_NS}" kubevirt-hyperconverged --for=condition=Available --timeout=15m; then
    echo "HyperConverged kubevirt-hyperconverged did not become Available"
    dump_cnv_olm
    oc get hyperconverged -n "${CNV_NS}" kubevirt-hyperconverged -o yaml || true
    exit 1
  fi
fi

if [ -n "$TUNING_POLICY" ]; then
  oc patch hyperconverged kubevirt-hyperconverged -n openshift-cnv --type=json -p="[{'op': 'add', 'path': '/spec/tuningPolicy', 'value': '$TUNING_POLICY'}]"
fi

# Wait for MachineConfigPool to finish rolling out any day-2 MachineConfig
# changes created by virt-platform-autopilot (e.g. psi=1 kernel arg,
# kubelet swap config). Without this wait, subsequent test steps may start
# while the MCO is still draining/rebooting worker nodes, causing test pod
# evictions and consistent failures.
# See: https://redhat-internal.slack.com/archives/C020CKMP6CT/p1788749810927519
echo "Waiting for worker MachineConfigPool to finish updating..."
oc wait mcp worker --for condition=Updated --timeout=30m
echo "Worker MachineConfigPool is updated, all nodes are ready."
