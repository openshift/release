# interop-mtr-execute-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
  - [Define Required Variables](#define-required-variables)
  - [Create MTR Test Configuration File](#create-mtr-test-configuration-file)
  - [Install MTR Tests](#install-mtr-tests)
  - [Start the local FTP Server](#start-the-local-ftp-server)
  - [Execute Tests](#execute-tests)
  - [Stop the local FTP Server](#stop-the-local-ftp-server)
- [Container Used](#container-used)
- [Requirements](#requirements)
  - [Variables](#variables)
  - [Infrastructure](#infrastructure)
  - [Credentials](#credentials)


## Purpose

To retrieve all of the required variables, use those variables to write a configuration file, install the Python MTR tests, and execute those tests against a test cluster using Selenium. The tests should produce valid XUnit results to be stored in the `SHARED_DIR` to be used by the [interop-mtr-report](../report/README.md) step. 

## Process

This script can be separated into 5 sections - Define required variables, create configuration file, install MTR tests, start the local FTP server, execute tests, and stop the local FTP server.

### Define Required Variables

Used to define the variables needed to [create the MTR test configuration file](#create-mtr-test-configuration-file). The variables defined in this step come from files in the `SHARED_DIR` and [credentials](#credentials) from Vault.

### Create MTR Test Configuration File

Used to create the MTR test configuration file needed to execute the tests properly against the test cluster. The file is created by replacing values in a [pre-defined yaml file within the container](https://github.com/windup/windup_integration_test/blob/mtr/dockerfiles/interop/env.yaml) using the `sed` command along with [variables](#define-required-variables) defined earlier in the script.

### Install MTR Tests

Uses `pip` to install the MTR tests from the `/tmp/integration_tests` directory within the container. These tests come from the the [windup/windup_integration_test](https://github.com/windup/windup_integration_test.git) repository maintained by MTR product QE. These tests must be installed in this script rather than when the container image is built because OpenShift runs these containers using a user that ends up not having access to [modify the configuration file](#create-mtr-test-configuration-file) needed to execute these tests. Because that configuration file changes with every run, we have to modify it *then* install the tests.

### Start the local FTP Server

Because these tests require an FTP server and the one used previously is behind our firewall, this image contains a script that will start a local FTP server that holds the `.war` needed to execute the tests.

### Execute Tests

Uses `pytest` to execute the Interop MTR tests. The XUnit/JUnit results are then published to the `${SHARED_DIR}/xunit_output.xml` file. This file is to be used in the [interop-mtr-report](../report/README.md) step of this scenario.


### Stop the local FTP Server

Stop the local FTP server that was started earlier in the script. If the process is left running, the execute pod will not complete and OpenShift CI will stop the pod after 2 hours, failing the execution.

## Container Used

The container used in this step is named `mtr-runner` in the [configuration file](../../../../windup/windup-windup_integration_test-mtr.yaml). This container created from a custom image located in the [windup/windup_integration_test repository](https://github.com/windup/windup_integration_test/blob/mtr/dockerfiles/interop/Dockerfile).

## Requirements

### Variables

- `CONFIG_FILE`
  - **Definition**: The path to the config file required for MTR test execution.
  - **If left empty**: The default value for this path is `/tmp/integration_tests/mta/conf/env.yaml` and **generally should not change**. This variable is here just in case it needs to be overridden in the future.
- `MTR_VERSION`
  - **Definition**: The version of the MTR operator you are testing. This variable is currently used in the MTR test configuration file.
  - **If left empty**: The test will fail.
### Infrastructure

- A provisioned test cluster to target.
- A Selenium container running in the test cluster that allows for ingress
  - This is taken care of in the [interop-mtr-orchestrate](../orchestrate/README.md) -> [interop-tooling-deploy-selenium](../../tooling/deploy-selenium/README.md) step

### Credentials

- `mtr-ftp-credentials`
  - **Collection**: [mtr-qe](https://vault.ci.openshift.org/ui/vault/secrets/kv/ddlist/selfservice/mtr-qe/)
  - **Usage**: Used to retrieve required files from the FTP server during test execution
  - **Mount Path**: `/tmp/secrets/ftp`
- `mtr-mtr-credentials`
  - **Collection**: [mtr-qe](https://vault.ci.openshift.org/ui/vault/secrets/kv/ddlist/selfservice/mtr-qe/)
  - **Usage**: Used in the MTR test config file to access the MTR operator.
  - **Mount Path**: `/tmp/secrets/mtr`