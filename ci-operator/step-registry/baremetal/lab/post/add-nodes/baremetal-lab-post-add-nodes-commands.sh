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

oc create -f ${DIR}/bmo.yaml
echo "Waiting up to 60 seconds for the metal3 pods to get created..."
for i in $(seq 1 6); do
  sleep 30
  if $(oc get pods -n openshift-machine-api --no-headers -l k8s-app=metal3 | \
       awk '{print $3}' | uniq | tr -d "\n" | grep -q -w Running); then
    break
  else
    [ "$i" -eq 6 ] && \
    echo "Creating resources to enable Metal platform components failed" && exit 1
  fi
done

oc create -f ${DIR}/master00-bmc.yaml
echo "Waiting up to 5 minutes for existing host enrollment"
for i in $(seq 1 6); do
  if [ "$i" -lt 6 ]; then
    sleep 60
    oc get bmh -A --no-headers | grep -w "externally provisioned"
    if ! $(oc get bmh -A --no-headers | grep -q -w "externally provisioned"); then
      echo "Enrolling existing host in progress"
    else
      sleep 30
      oc get bmh -A --no-headers -o jsonpath='{.items[0].status.online}'
      if ! $(oc get bmh -A --no-headers -o jsonpath='{.items[0].status.online}'| grep -q -w true); then
        echo "Enrolled existing host is not Online"
        exit 1
      else
        break
      fi
    fi
  else
    echo "Timeout reached while waiting for existing host enrollment. Failing..."
    exit 1
  fi
done

#Adding new worker node
for addhost in $(yq e -o=j -I=0 '.[] | select(.name|test("worker-a-"))' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$addhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  if [ ${#bmc_address} -eq 0 ] || [ ${#bmc_user} -eq 0 ] || [ ${#bmc_pass} -eq 0 ]; then
    echo "Error while unmarshalling hosts entries"
    exit 1
  fi
  echo "Creating resource file for ${name}"
  cat > ${DIR}/${name}-bmc.yaml <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: "${name}-bmc"
  namespace: openshift-machine-api
type: Opaque
data:
  username: "$redfish_user"
  password: "$redfish_password"
---
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: "$name"
  namespace: openshift-machine-api
spec:
  bmc:
    address: "redfish-virtualmedia://$bmc_address/redfish/v1/Systems/1"
    credentialsName: "${name}-bmc"
    disableCertificateVerification: True
  bootMACAddress: "$provisioning_mac"
  bootMode: legacy
  customDeploy:
    method: install_coreos
  online: true
  userData:
    name: worker-user-data-managed
    namespace: openshift-machine-api

EOF

  echo "Adding node ${name} ..."
  oc create -f ${DIR}/${name}-bmc.yaml
  echo "Waiting up to 5 minutes for enrolling new host"
  for i in $(seq 1 6); do
    if [ "$i" < 6 ]; then
      sleep 60
      oc get bmh -A --no-headers | grep ${name} | grep -w "provisioned"
      if ! $(oc get bmh -A --no-headers | grep ${name} | grep -q -w "provisioned"); then
        echo "Enrolling new host in progress"
      else
        sleep 30
        oc get bmh -A --no-headers -o jsonpath='{.items[1].status.online}'
        if ! $(oc get bmh -A --no-headers -o jsonpath='{.items[1].status.online}'| grep -q -w true); then
          echo "Enrolled existing host is not Online"
          exit 1
        fi
        break
      fi
    else
      echo "Timeout reached while waiting for new host enrollment. Failing..."
      exit 1
    fi
  done
done
