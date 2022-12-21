#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Verify the arguments provided in the .environment variables. 
#If any of the variables are not set and are able to be set using automation, this snippet takes care of assigning values to the unset variables.
if [[ -z "${SUB_INSTALL_NAMESPACE}" ]]; then
  echo "SUB_INSTALL_NAMESPACE is not defined, using ${NAMESPACE}"
  SUB_INSTALL_NAMESPACE=${NAMESPACE}
fi

if [[ -z "${SUB_TARGET_NAMESPACES}" ]]; then
  echo "SUB_TARGET_NAMESPACES is not defined, using ${NAMESPACE}"
  SUB_TARGET_NAMESPACES=${NAMESPACE}
fi

# Exit if SUB_PACKAGE is not defined
if [[ -z "${SUB_PACKAGE}" ]]; then
  echo "ERROR: PACKAGE is not defined"
  exit 1
fi

# Use the default channel if one isn't defined
if [[ -z "${SUB_CHANNEL}" ]]; then
  echo "INFO: CHANNEL is not defined, using default channel"
  SUB_CHANNEL=$(oc get packagemanifest "${SUB_PACKAGE}" -o jsonpath='{.status.defaultChannel}')
  
  if [[ -z "${SUB_CHANNEL}" ]]; then
    echo "ERROR: Default channel not found."
    exit 1
  else
    echo "INFO: Default channel is ${SUB_CHANNEL}"
  fi
fi

# Set SUB_TARGET_NAMESPACES to the SUB_INSTALL_NAMESPACE value if it isn't set to "!install"
if [[ "${SUB_TARGET_NAMESPACES}" == "!install" ]]; then
  SUB_TARGET_NAMESPACES="${SUB_INSTALL_NAMESPACE}"
fi

echo "Installing ${SUB_PACKAGE} from ${SUB_CHANNEL} into ${SUB_INSTALL_NAMESPACE}, targeting ${SUB_TARGET_NAMESPACES}"

# Create the Namespace that the operator will be installed on. 
# This command is idempotent, so if the Namespace already exists, it will just continue with the rest of the script.
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${SUB_INSTALL_NAMESPACE}"
EOF

# Deploy a new OperatorGroup in the Namespace that was just created.
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${SUB_INSTALL_NAMESPACE}-operator-group"
  namespace: "${SUB_INSTALL_NAMESPACE}"
spec:
  targetNamespaces:
  - $(echo \"${SUB_TARGET_NAMESPACES}\" | sed "s|,|\"\n  - \"|g")
EOF

# Create the subscription for the operator and finish the install portion of this script.
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${SUB_PACKAGE}"
  namespace: "${SUB_INSTALL_NAMESPACE}"
spec:
  channel: "${SUB_CHANNEL}"
  installPlanApproval: Automatic
  name: "${SUB_PACKAGE}"
  source: "${SUB_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF

# Can't wait before the resource exists. Need to sleep a bit before start watching
sleep 60

# Verify that the operator is installed successfully. 
# It will check the status of the installation every 30 seconds until it has reached 30 retries. 
# If the operator is not installed successfully, it will retrieve information about the subscription and print that information for debugging.
RETRIES=30
CSV=
for i in $(seq "${RETRIES}"); do
  if [[ -z "${CSV}" ]]; then
    CSV=$(oc get subscription -n "${SUB_INSTALL_NAMESPACE}" "${SUB_PACKAGE}" -o jsonpath='{.status.currentCSV}')
  fi

  if [[ -z "${CSV}" ]]; then
    echo "Try ${i}/${RETRIES}: can't get the ${SUB_PACKAGE} yet. Checking again in 30 seconds"
    sleep 30
  fi

  if [[ $(oc get csv -n ${SUB_INSTALL_NAMESPACE} ${CSV} -o jsonpath='{.status.phase}') == "Succeeded" ]]; then
    echo "${SUB_PACKAGE} is deployed"
    break
  else
    echo "Try ${i}/${RETRIES}: ${SUB_PACKAGE} is not deployed yet. Checking again in 30 seconds"
    sleep 30
  fi
done

if [[ $(oc get csv -n "${SUB_INSTALL_NAMESPACE}" "${CSV}" -o jsonpath='{.status.phase}') != "Succeeded" ]]; then
  echo "Error: Failed to deploy ${SUB_PACKAGE}"

  echo "SUBSCRIPTION YAML"
  oc get subscription -n "${SUB_INSTALL_NAMESPACE}" "${SUB_PACKAGE}" -o yaml

  echo "CSV ${CSV} YAML"
  oc get CSV "${CSV}" -n "${SUB_INSTALL_NAMESPACE}" -o yaml

  echo "CSV ${CSV} Describe"
  oc describe CSV "${CSV}" -n "${SUB_INSTALL_NAMESPACE}"

  exit 1
fi

echo "Successfully installed ${SUB_PACKAGE}"
