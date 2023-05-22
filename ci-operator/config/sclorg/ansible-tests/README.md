# rhscl-ansible-tests-main<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning: `ipi-aws`](#cluster-provisioning-and-deprovisioning-ipi-aws)
  - [Test Setup, Execution, and Reporting Results - `dotnet-interop-aws`](#test-setup-execution-and-reporting-results---dotnet-interop-aws)
- [Prerequisite(s)](#prerequisites)
  - [Environment Variables](#environment-variables)
  - [Custom Images](#custom-images)

## General Information

- **Repository**: [rhscl/ansible-tests](https://github.com/rhscl/ansible-tests)
- **Operator Tested**: [.NET (Runtimes and APIs for building and running .NET applications on Linux and in containers)](https://developers.redhat.com/products/dotnet/overview)

## Purpose

To provision the necessary infrastructure and using that infrastructure to execute .NET interop tests. The results of these tests will be reported to the appropriate sources following execution.

## Process

The .NET Core Interop scenario can be broken into the following basic steps:

1. Provision a test cluster on AWS
2. Deploy and Execute tests and archive results
3. Deprovision a test cluster.

### Cluster Provisioning and Deprovisioning: `ipi-aws`

Please see the [`ipi-aws`](https://steps.ci.openshift.org/workflow/ipi-aws) documentation for more information on this workflow. This workflow is not maintained by the Interop QE team.

### Test Setup, Execution, and Reporting Results - `dotnet-interop-aws`

Following the test cluster being provisioned, the following steps are executed in this order:

1. [`dotnet-deploy-and-test`](../../../step-registry/sclorg/README.md)

## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
  - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
  - **If left empty**: The [`ipi-aws` workflow](../../../step-registry/ipi/aws/ipi-aws-workflow.yaml) will fail.
- `DOTNET_VERSION`
  - **Definition**: Used to specify Dotnet versions to test (dotnet, dotnet_60 dotnet_70). This value will determine which version of .NET to run tests for.
  - **If left empty**: It will use 'dotnet' as the default value. Meaning tests will executed for all valid versions.


### Custom Images

- `dotnet-runner`
  - [Dockerfile](https://github.com/sclorg/ansible-tests/blob/master/Dockerfile)
  - The custom image for this step uses the [`Ansible Automation Platform compatibility execution environment`](registry.redhat.io/ansible-automation-platform/ee-29-rhel8:latest) image as it's base. The image should have all of the required dependencies installed and the [scl/ansible-tests repository](https://github.com/sclorg/ansible-tests) copied into `/tmp/tests/ansible-tests`.


