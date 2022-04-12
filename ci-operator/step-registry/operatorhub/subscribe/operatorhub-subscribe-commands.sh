#!/usr/bin/env bash

set -ex

#set -o nounset
#set -o errexit
#set -o pipefail

if [[ -z ${INSTALL_NAMESPACE} ]]; then
  echo "ERROR: INSTALL_NAMESPACE is not defined"
  exit 1
fi

if [[ -z ${PACKAGE} ]]; then
  echo "ERROR: PACKAGE is not defined"
  exit 1
fi

if [[ -z ${CHANNEL} ]]; then
  echo "ERROR: CHANNEL is not defined"
  exit 1
fi

if [[ ${TARGET_NAMESPACES} == "!install" ]]; then
  TARGET_NAMESPACES=${INSTALL_NAMESPACE}
fi

echo "Installing ${PACKAGE} from ${CHANNEL} into ${INSTALL_NAMESPACE}, targeting ${TARGET_NAMESPACES}"

SOURCE=${SOURCE:-redhat-operators}

# create the install namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${INSTALL_NAMESPACE}
EOF

# deploy new operator group
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${INSTALL_NAMESPACE}-operator-group
  namespace: ${INSTALL_NAMESPACE}
spec:
  targetNamespaces:
  - $(echo \"${TARGET_NAMESPACES}\" | sed "s|,|\"\n  - \"|g")
EOF

# subscribe to the operator
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${PACKAGE}
  namespace: ${INSTALL_NAMESPACE}
spec:
  channel: ${CHANNEL}
  installPlanApproval: Automatic
  name: ${PACKAGE}
  source: ${SOURCE}
  sourceNamespace: openshift-marketplace
EOF

# can't wait before the resource exists. Need to sleep a bit before start watching
sleep 60

RETRIES=30
CSV=
for i in $(seq ${RETRIES}); do
  if [[ -z ${CSV} ]]; then
    CSV=$(oc get subscription -n ${INSTALL_NAMESPACE} ${PACKAGE} -o jsonpath='{.status.installedCSV}')
  fi

  if [[ -z ${CSV} ]]; then
    echo "Try ${i}/${RETRIES}: can't get the ${PACKAGE} yet. Checking again in 30 seconds"
    sleep 30
  fi

  if [[ $(oc get csv -n ${INSTALL_NAMESPACE} ${CSV} -o jsonpath={.status.phase}) == "Succeeded" ]]; then
    echo "${PACKAGE} is deployed"
    break
  else
    echo "Try ${i}/${RETRIES}: ${PACKAGE} is not deployed yet. Checking again in 30 seconds"
    sleep 30
  fi
done

if [[ $(oc get csv -n ${INSTALL_NAMESPACE} ${CSV} -o jsonpath={.status.phase}) != "Succeeded" ]]; then
  echo "Error: Failed to deploy ${PACKAGE}"
  echo "CSV ${CSV} YAML"
  oc get CSV ${CSV} -n ${INSTALL_NAMESPACE} -o yaml
  echo
  echo "CSV ${CSV} Describe"
  oc describe CSV ${CSV} -n ${INSTALL_NAMESPACE}
  exit 1
fi

echo "successfully installed ${PACKAGE}"
