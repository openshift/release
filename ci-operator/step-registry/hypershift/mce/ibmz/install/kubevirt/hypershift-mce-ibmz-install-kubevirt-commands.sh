#!/usr/bin/env bash

set -ex

# The kubevirt tests require wildcard routes to be allowed
oc patch ingresscontroller -n openshift-ingress-operator default --type=json -p '[{ "op": "add", "path": "/spec/routeAdmission", "value": {wildcardPolicy: "WildcardsAllowed"}}]'

# Make the masters schedulable so we have more capacity to run VMs
CONTROL_PLANE_TOPOLOGY=$(oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}')
if [[ ${CONTROL_PLANE_TOPOLOGY} != "External" ]]
then
  oc patch scheduler cluster --type=json -p '[{ "op": "replace", "path": "/spec/mastersSchedulable", "value": true }]'
fi

# In case of nested-mgmt topology where there's only one worker node, we need to label it as a master
# in order to get some kubevirt components to be scheduled. This is needed since CNV 4.17.0+
if [[ $(oc get nodes --no-headers | wc -l) -eq 1 ]]
then
	NODENAME=$(oc get nodes -o jsonpath='{.items[].metadata.name}')
	oc label node ${NODENAME} node-role.kubernetes.io/control-plane=
fi

oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cnv
EOF

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-cnv-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
  - openshift-cnv
EOF

VIRT_OPERATOR_SUB_SOURCE=$(
cat <<EOF | awk '/name:/ {print $2; exit}'
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: redhat-operators-stage
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  publisher: redhat
  displayName: Red Hat Operators v4.19 Stage
  image: quay.io/openshift-release-dev/ocp-release-nightly:iib-int-index-art-operators-4.19
  updateStrategy:
    registryPoll:
      interval: 15m
EOF
)

echo "$VIRT_OPERATOR_SUB_SOURCE"

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  labels:
    operators.coreos.com/kubevirt-hyperconverged.openshift-cnv: ''
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  channel: stable
  installPlanApproval: Automatic
  name: kubevirt-hyperconverged
  source: "${VIRT_OPERATOR_SUB_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF



sleep 30

RETRIES=30
CSV=
for i in $(seq ${RETRIES}); do
  if [[ -z ${CSV} ]]; then
    CSV=$(oc get subscription -n openshift-cnv kubevirt-hyperconverged -o jsonpath='{.status.installedCSV}')
  fi
  if [[ -z ${CSV} ]]; then
    echo "Try ${i}/${RETRIES}: can't get the CSV yet. Checking again in 30 seconds"
    sleep 30
  fi
  if [[ $(oc get csv -n openshift-cnv ${CSV} -o jsonpath='{.status.phase}') == "Succeeded" ]]; then
    echo "CNV is deployed"
    break
  else
    echo "Try ${i}/${RETRIES}: CNV is not deployed yet. Checking again in 30 seconds"
    sleep 30
  fi
done

if [[ $(oc get csv -n openshift-cnv ${CSV} -o jsonpath='{.status.phase}') != "Succeeded" ]]; then
  echo "Error: Failed to deploy CNV"
  echo "CSV ${CSV} YAML"
  oc get CSV ${CSV} -n openshift-cnv -o yaml
  echo
  echo "CSV ${CSV} Describe"
  oc describe CSV ${CSV} -n openshift-cnv
  exit 1
fi

# Deploy HyperConverged custom resource to complete kubevirt's installation
oc create -f - <<EOF
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  featureGates:
    enableCommonBootImageImport: false
  logVerbosityConfig:
    kubevirt:
      virtLauncher: 8
      virtHandler: 8
      virtController: 8
      virtApi: 8
      virtOperator: 8
EOF

oc wait hyperconverged -n openshift-cnv kubevirt-hyperconverged --for=condition=Available --timeout=15m

if oc get pods -n openshift-cnv 2>/dev/null | grep -E "Running" >/dev/null; then
    echo "✅ Successfully installed virtualtisation operator."
else
    echo "❌ virtualtisation operator installation failed."
    exit 1
fi

echo "Installing VM console logger in order to aid debugging potential VM boot issues"
oc apply -f https://raw.githubusercontent.com/davidvossel/kubevirt-console-debugger/main/kubevirt-console-logger.yaml


if [ "$(oc get infrastructure cluster -o=jsonpath='{.status.platformStatus.type}')" == "Azure" ];
then
  # Pin cpuModel to Broadwell in case of Azure cluster, to avoid discrepancies between the cluster nodes
  PATCH_COMMAND="oc patch hco kubevirt-hyperconverged -n openshift-cnv --type=json -p='[{\"op\": \"add\", \"path\": \"/spec/defaultCPUModel\", \"value\": \"Broadwell\"}]'"
  MAX_RETRIES=5
  for ((i=1; i<=MAX_RETRIES; i++)); do
    echo "Attempt $i of $MAX_RETRIES..."
    if eval $PATCH_COMMAND; then
      echo "Patch succeeded."
      exit 0
    else
      echo "Patch failed. Retrying in 2 seconds..."
      sleep 2
    fi
  done

  echo "Patch failed after $MAX_RETRIES attempts."
  exit 1
fi
