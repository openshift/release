# interop-mtr-chain<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
  - [MTR Chain Steps](#mtr-chain-steps)
- [Requirements](#requirements)
  - [Variables](#variables)
  - [Infrastructure](#infrastructure)
  - [Credentials](#credentials)

## Purpose

To prepare an environment and execute interop testing for the MTR (previously MTA) operator on the most recent version of OpenShift. The tests are maintained in the [windup/windup_integration_test](https://github.com/windup/windup_integration_test.git) repository by MTR product QE.

This chain is to be used by the [windup-windup_integration_test-main](../../../config/calebevans/windup_integration_test/README.md) configuration

## Process

The process for this scenario attempts to follow a general flow of orchestrate, execute, report.

- **Orchestrate**: Install any necessary operators and additional infrastructure for testing.
- **Execute**: Execute the tests from the test repository.
- **Report**: Publish XUnit results to Report Portal or any other platform needed.

### MTR Chain Steps

Below is a list of steps and sub-steps executed within this chain. Each step is linked to the step's README file, if you'd like to learn more about a step, please follow the links to those pages. Retrieve 

1. [interop-mtr-orchestrate](orchestrate/README.md)
    1. [interop-tooling-operator-install](../tooling/operator-install/README.md)
    2. [interop-mtr-orchestrate-deploy-windup](orchestrate/deploy-windup/README.md)
    3. [interop-mtr-orchestrate-retrieve-console-url](orchestrate/retrieve-console-url/README.md)
    4. [interop-tooling-deploy-selenium](../tooling/deploy-selenium/README.md)
2. [interop-mtr-execute](execute/README.md)
3. [interop-mtr-report](report/README.md)

## Requirements

### Variables

- [interop-mtr-orchestrate](orchestrate/README.md)
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
- [interop-mtr-execute](execute/README.md)
  - `CONFIG_FILE`
    - **Definition**: The path to the config file required for MTR test execution.
    - **If left empty**: The default value for this path is `/tmp/integration_tests/mta/conf/env.yaml` and **generally should not change**. This variable is here just in case it needs to be overridden in the future.
- [interop-mtr-report](report/README.md)

### Infrastructure

- A provisioned test cluster to target.
  - Should have enough space to hold a 5Gi volume
  - This cluster should have a `mtr` Namespace with the MTR operator installed on it. 
    - This is taken care of in the [interop-mtr-orchestrate](orchestrate/README.md) -> [interop-tooling-operator-install](../tooling/operator-install/README.md) step
- A Selenium container running in the test cluster that allows for ingress
  - This is taken care of in the [interop-mtr-orchestrate](orchestrate/README.md) -> [interop-tooling-deploy-selenium](../tooling/deploy-selenium/README.md) step

### Credentials

- [interop-mtr-execute](execute/README.md)
  - `mtr-ftp-credentials`
    - **Collection**: [mtr-qe](https://vault.ci.openshift.org/ui/vault/secrets/kv/ddlist/selfservice/mtr-qe/)
    - **Usage**: Used to retrieve required files from the FTP server during test execution