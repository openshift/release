#!/bin/bash

set -o nounset
set -o pipefail

CLUSTER_NAME="${NAMESPACE}"
DIR=/tmp/bmo
mkdir -p ${DIR}

master00_addr=$(yq e '.[] | select(.name == "master-00") | .bmc_address' ${SHARED_DIR}/hosts.yaml)
master00_bootMacAddr=$(yq e '.[] | select(.name == "master-00") | .provisioning_mac' ${SHARED_DIR}/hosts.yaml)
master00_username=$(yq e '.[] | select(.name == "master-00") | .bmc_user' ${SHARED_DIR}/hosts.yaml)
master00_pass=$(yq e '.[] | select(.name == "master-00") | .bmc_pass' ${SHARED_DIR}/hosts.yaml)

workera_addr=$(yq e '.[] | select(.name == "worker-a-00") | .bmc_address' ${SHARED_DIR}/hosts.yaml)
workera_bootMacAddr=$(yq e '.[] | select(.name == "worker-a-00") | .provisioning_mac' ${SHARED_DIR}/hosts.yaml)
workera_username=$(yq e '.[] | select(.name == "worker-a-00") | .bmc_user' ${SHARED_DIR}/hosts.yaml)
workera_pass=$(yq e '.[] | select(.name == "worker-a-00") | .bmc_pass' ${SHARED_DIR}/hosts.yaml)

cat > ${DIR}/bmo.yaml <<EOF
apiVersion: metal3.io/v1alpha1
kind: Provisioning
metadata:
  name: provisioning-configuration
spec:
  provisioningNetwork: "Disabled"
  watchAllNamespaces: false

EOF

cat > ${DIR}/master00-bmc.yaml <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: master00-bmc
  namespace: openshift-machine-api
type: Opaque
data:
  username: "$master00_username"
  password: "$master00_pass"
---
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: master00
  namespace: openshift-machine-api
spec:
  bmc:
    address: "redfish-virtualmedia://$master00_addr/redfish/v1/Systems/1"
    credentialsName: "master00-bmc"
    disableCertificateVerification: True
  bootMACAddress: "$master00_bootMacAddr"
  customDeploy:
    method: install_coreos
  externallyProvisioned: true
  online: true
  userData:
    name: master-user-data-managed
    namespace: openshift-machine-api

EOF

cat > ${DIR}/workera-bmc.yaml <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: workera-bmc
  namespace: openshift-machine-api
type: Opaque
data:
  username: "$workera_username"
  password: "$worker_pass"
---
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: worker-a-00
  namespace: openshift-machine-api
spec:
  bmc:
    address: "redfish-virtualmedia://$workera_addr/redfish/v1/Systems/1"
    credentialsName: "workera-bmc"
    disableCertificateVerification: True
  bootMACAddress: "$workera_bootMacAddr"
  bootMode: legacy
  customDeploy:
    method: install_coreos
  online: true
  userData:
    name: worker-user-data-managed
    namespace: openshift-machine-api

EOF


oc create -f ${DIR}/bmo.yaml 
echo "Waiting up to 60 seconds for the metal3 pods to get created..."
sleep 60
while IFS= read -r line; do
  if [[ $line != *"Running"* ]]; then
    echo "Creating resources to enable Metal platform components failed"
    exit 1
  fi
done <<< "oc get pods -n openshift-machine-api --no-headers -l k8s-app=metal3"

oc create -f ${DIR}/master00-bmc.yaml
echo "Waiting up to 5 minutes for existing host enrollment"
for _ in $(seq 1 5); do
  sleep 60
  oc get bmh -A --no-headers | grep -q -w "externally provisioned"
  if ! $(oc get bmh -A --no-headers | grep -q -w "externally provisioned"); then
    echo "Enrolling existing host in progress"
  else
    sleep 30
    oc get bmh -A --no-headers -o jsonpath='{.items[0].status.online}'
    if ! $(oc get bmh -A --no-headers -o jsonpath='{.items[0].status.online}'| grep -q -w true); then
      echo "Enrolled existing host is not Online"
      exit 1
    fi
  fi
done

oc create -f ${DIR}/worker03-bmc.yaml
echo "Waiting up to 5 minutes for enrolling new host"
for _ in $(seq 1 5); do
  sleep 60
  oc get bmh -A --no-headers | grep worker-a-00 | grep -q -w "provisioned"
  if ! $(oc get bmh -A --no-headers | grep worker03 | grep -q -w "provisioned"); then
    echo "Enrolling new host in progress"
  else
    sleep 30
    oc get bmh -A --no-headers -o jsonpath='{.items[1].status.online}'
    if ! $(oc get bmh -A --no-headers -o jsonpath='{.items[1].status.online}'| grep -q -w true); then
      echo "Enrolled existing host is not Online"
      exit 1
    fi
    exit 0
  fi
done
echo "Timeout reached while waiting for new host enrollment. Failing..."
exit 1
