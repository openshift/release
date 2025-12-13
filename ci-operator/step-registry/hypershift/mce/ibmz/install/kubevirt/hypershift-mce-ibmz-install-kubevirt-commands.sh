#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x


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
  source: redhat-operators
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

echo "⏳ Waiting for all pods in openshift-cnv to become Running..."

oc wait pod \
  -n openshift-cnv \
  --all \
  --for=condition=Ready \
  --timeout=15m

echo "✅ All pods in openshift-cnv are Ready."

echo "Installing VM console logger in order to aid debugging potential VM boot issues"
oc apply -f https://raw.githubusercontent.com/davidvossel/kubevirt-console-debugger/main/kubevirt-console-logger.yaml


