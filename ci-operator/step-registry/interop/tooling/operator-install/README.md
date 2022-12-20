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

Used in the script to verify the arguments provided in the [environment variables](#variables). If any of the variables are not set and are able to be set using automation, this snippet takes care of assigning values to the unset variables.

### Install the Operator

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

Deploy a new OperatorGroup in the Namespace that was just created.

#### Subscribe to the Operator

Create the subscription for the operator and finish the install portion of this script.

### Verify Operator Installation

Verify that the operator is installed successfully. It will check the status of the installation every 30 seconds until it has reached 30 retries. If the operator is not installed successfully, it will retrieve information about the subscription and print that information for debugging.

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