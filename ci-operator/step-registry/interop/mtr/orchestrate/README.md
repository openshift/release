# interop-mtr-orchestrate-chain<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
  - [interop-tooling-operator-install](#interop-tooling-operator-install)
  - [interop-mtr-orchestrate-deploy-windup](#interop-mtr-orchestrate-deploy-windup)
  - [interop-mtr-orchestrate-retrieve-console-url](#interop-mtr-orchestrate-retrieve-console-url)
  - [interop-tooling-deploy-selenium](#interop-tooling-deploy-selenium)
- [Requirements](#requirements)
  - [Variables](#variables)
  - [Infrastructure](#infrastructure)

## Purpose

To prepare the MTR environment for the execution of interop testing of the MTR (previously MTA) operator on the most recent version of OpenShift. This step comes after a test cluster has already been provisioned. All steps are executed in the OpenShift CI cluster but any `oc` commands are executed on the test cluster.

## Process

This chain executes 4 refs in order:

1. [interop-tooling-operator-install](../tooling/operator-install/README.md)
2. [interop-mtr-orchestrate-deploy-windup](orchestrate/deploy-windup/README.md)
3. [interop-mtr-orchestrate-retrieve-console-url](orchestrate/retrieve-console-url/README.md)
4. [interop-tooling-deploy-selenium](../tooling/deploy-selenium/README.md)

Here is a brief explanation of each step. If you'd like to know more about each step please visit that step's README document linked in the list above:

### interop-tooling-operator-install

This interop tooling ref is used to install the MTR operator on the test cluster using the environment variables provided in the scenario's config.

### interop-mtr-orchestrate-deploy-windup

Used to deploy Windup to the "mtr" namespace with a 5Gi volumeCapacity and wait 5 minutes for it to finish deploying.

### interop-mtr-orchestrate-retrieve-console-url

Used to retrieve the console URL of the test cluster and write it to the "apps_url" file in the SHARED_DIR for use later.

### interop-tooling-deploy-selenium

This interop tooling ref is used to deploy a Selenium container along with it's required network configurations to a specified namespace in the test cluster. This container is used for test execution.

## Requirements

### Variables

- [interop-tooling-operator-install](../tooling/operator-install/README.md)
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
- [interop-mtr-orchestrate-deploy-windup](orchestrate/deploy-windup/README.md)
  - **NONE**
- [interop-mtr-orchestrate-retrieve-console-url](orchestrate/retrieve-console-url/README.md)
  - **NONE**
- [interop-tooling-deploy-selenium](../tooling/deploy-selenium/README.md)
  - `SELENIUM_NAMESPACE`
    - **Definition**: The namespace that the Selenium pod and the supporting network infrastructure will be deployed in.
    - **If left empty**: The script will use the `selenium` namespace.
    - **Additional information**: If the requested namespace does not exist, it will be created.

### Infrastructure

- A provisioned test cluster to target.
  - Should have enough space to hold a 5Gi volume
  - This cluster should have a `mtr` Namespace with the MTR operator installed on it. (This is taken care of in the [interop-tooling-operator-install](../tooling/operator-install/README.md) step)