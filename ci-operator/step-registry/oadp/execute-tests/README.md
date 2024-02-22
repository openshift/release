# oadp-execute-tests-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To execute the OADP interop test suite against a provisioned test cluster.

## Process

This script is executed in the following steps:

1. Sets all variables needed to execute the tests. Definitions for many of these variables can be [found in the oadp-qe/oadp-e2e-qe repository](https://github.com/oadp-qe/oadp-e2e-qe/blob/release-v1.1/docs/overview/test_runner_vars.md).
2. Extracts the tar archives of the [oadp-qe/oadp-e2e-qe](https://github.com/oadp-qe/oadp-e2e-qe), [oadp-qe/oadp-apps-deployer](https://github.com/oadp-qe/oadp-apps-deployer), and [oadp-qe/mtc-python-client](https://github.com/oadp-qe/mtc-python-client) repositories to their respective directories.
3. Create and populate the the `/tmp/test-settings` directory to be used by the test suite.
4. Login to the test cluster as the `kubeadmin` user. The pod will already be logged in as the `system:admin`, but that user does not have a token associated with it and will break the tests.
6. Create a Python virtual environment and install the necessary packages for test execution.
7. Execute the tests using a [script maintained by OADP QE in the oadp-qe/oadp-e2e-qe repository](https://github.com/oadp-qe/oadp-e2e-qe/blob/release-v1.1/test_settings/scripts/test_runner.sh).
8. Copy the junit results in to the `$ARTIFACT_DIR`

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.
  - The test cluster should have the necessary operators installed prior to testing. This should be taken care of in the [`install-operators`](../../install-operators/README.md) ref using the `OPERATORS` variable defined in the configuration file for the OADP scenario.

### Environment Variables

- `BUCKET_NAME`
  - **Definition**: The name of the bucket created for test execution. The bucket name will actually be `$NAMESPACE-$BUCKET_NAME` to avoid any potential naming conflicts.
  - **If left empty**: A default value of `interopoadp` will be used.
- `OADP_CLOUD_PROVIDER`
  - **Definition**: The cloud provider the test cluster is provisioned on. [See OADP documentation for more information](https://github.com/oadp-qe/oadp-e2e-qe/blob/release-v1.1/docs/overview/test_runner_vars.md).
  - **If left empty**: A default value of `aws` will be used.
- `OADP_BACKUP_LOCATION`
  - **Definition**: The cloud provider the backup location is provisioned on. [See OADP documentation for more information](https://github.com/oadp-qe/oadp-e2e-qe/blob/release-v1.1/docs/overview/test_runner_vars.md).
  - **If left empty**: A default value of `aws` will be used.
- `OADP_TEST_FOCUS`
  - **Definition**: The Ginkgo focus used to define which tests in the suite should be run.
  - **If left empty**: A default value of `interop` will be used.
- `OADP_CREDS_FILE`
  - **Definition**: The path to the `credentials` file used to access the OADP backup location.
  - **If left empty**: A default value of `/tmp/test-settings/credentials` will be used.




