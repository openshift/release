# interop-tooling-operator-install-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
  - [Verify Arguments](#verify-arguments)
  - [Install the Operator](#install-the-operator)
    - [Create the Namespace](#create-the-namespace)
    - [Deploy a New OperatorGroup](#deploy-a-new-operatorgroup)
    - [Subscribe to the Operator](#subscribe-to-the-operator)
  - [Verify Operator Installation](#verify-operator-installation)
- [Container Used](#container-used)
- [Requirements](#requirements)
  - [Variables](#variables)
  - [Infrastructure](#infrastructure)

## Purpose

To install a specified operator to a test cluster using the variables outlined in the [Variables](#variables) section as arguments.

## Process

This script is fairly straightforward and can be broken into three parts: verify arguments, install operator, verify operator installation.

### Verify Arguments

The following code snippet is used in the script to verify the arguments provided in the [environment variables](#variables). If any of the variables are not set and are able to be set using automation, this snippet takes care of assigning values to the unset variables.

```bash
if [[ -z "${SUB_INSTALL_NAMESPACE}" ]]; then
  echo "SUB_INSTALL_NAMESPACE is not defined, using ${NAMESPACE}"
  SUB_INSTALL_NAMESPACE=${NAMESPACE}
fi

if [[ -z "${SUB_TARGET_NAMESPACES}" ]]; then
  echo "SUB_TARGET_NAMESPACES is not defined, using ${NAMESPACE}"
  SUB_TARGET_NAMESPACES=${NAMESPACE}
fi

if [[ -z "${SUB_PACKAGE}" ]]; then
  echo "ERROR: PACKAGE is not defined"
  exit 1
fi

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

if [[ "${SUB_TARGET_NAMESPACES}" == "!install" ]]; then
  SUB_TARGET_NAMESPACES="${SUB_INSTALL_NAMESPACE}"
fi
```

### Install the Operator

The following code snippets are used to install the specified operator using the `oc` tool. 

#### Create the Namespace
The following command is used to create the Namespace that the operator will be installed on. This command is idempotent, so if the Namespace already exists, it will just continue with the rest of the script.

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${SUB_INSTALL_NAMESPACE}"
EOF
```

#### Deploy a New OperatorGroup
The following command is used to deploy a new OperatorGroup in the Namespace that was just created.

```bash
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
```

#### Subscribe to the Operator
The following command will create the subscription for the operator and finish the install portion of this script.

```bash
cat <<EOF | oc apply -f -
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
```

### Verify Operator Installation

The following code snippet is used to verify that the operator is installed successfully. It will check the status of the installation every 30 seconds until it has reached 30 retries. If the operator is not installed successfully, it will retrieve information about the subscription and print that information for debugging.

```bash
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
```
## Container Used

The container used to execute this step is the built-in `cli`image.

## Requirements

### Variables

- `SUB_INSTALL_NAMESPACE` 
  - **Definition**: The namespace into which the operator and catalog will be installed.
  - **If left empty**: A new namespace will be created using the value of `$NAMESPACE` as the name. Typically this would result in using the name of the namespace that the container running this script is in. This is not recommended.
- `SUB_PACKAGE`
  - **Definition**: The package name of the optional operator to install.
  - **If left empty**: Cannot be empty. This will result in a failure
- `SUB_SOURCE`
  - **Definition**: The catalog source name.
  - **If left empty**: `redhat-operators` will be used as the catalog source
- `SUB_TARGET_NAMESPACES`
  - **Definition**: A comma-separated list of namespaces the operator will target. 
  - **If left empty**: All namespaces will be targeted.
  - **Additional information**: If no OperatorGroup exists in `SUB_INSTALL_NAMESPACE`, a new one will be created with its target namespaces set to `SUB_TARGET_NAMESPACES`, otherwise the existing OperatorGroup's target namespace set will be replaced. The special value "!install" will set the target namespace to the operator's installation namespace.
- `SUB_CHANNEL`
  - **Definition**: The channel from which to install the package.
  - **If left empty**: The default channel of `SUB_PACKAGE` will be used.

### Infrastructure

- A provisioned test cluster to target.