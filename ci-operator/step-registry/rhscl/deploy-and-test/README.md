# rhscl-ansible-tests-main<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning: `ipi-aws`](#cluster-provisioning-and-deprovisioning-ipi-aws)
  - [Test Setup, Execution, and Reporting Results - `rhscl-interop-aws`](#test-setup-execution-and-reporting-results---rhscl-interop-aws)
- [Prerequisite(s)](#prerequisites)
  - [Environment Variables](#environment-variables)
  - [Custom Images](#custom-images)

## General Information

- **Test Repository**: [sclorg/ansible-tests](https://github.com/sclorg/ansible-tests)
- **Product Tested**: [RHSCL](https://developers.redhat.com/products/red-hat-software-collections/overview)

## Purpose

To provision the necessary infrastructure and using that infrastructure to execute RHSCL interop tests. The results of these tests will be reported to the appropriate sources following execution.

## Process

The RHSCL Core Interop scenario can be broken into the following basic steps:

1. Provision a test cluster on AWS
2. Deploy and Execute tests and archive results
3. Deprovision a test cluster.

### Cluster Provisioning and Deprovisioning: `ipi-aws`

Please see the [`firewatch-ipi-aws`](https://steps.ci.openshift.org/workflow/firewatch-ipi-aws)documentation for more information on this workflow. This workflow is not maintained by the Interop QE team.

### Test Setup, Execution, and Reporting Results - `rhscl-interop-aws`

- The dockerfile to build the image and execute tests is defined at https://github.com/sclorg/ansible-tests/blob/master/dockerfiles/interop/Dockerfile

## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
  - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
  - **If left empty**: The [`firewatch-ipi-aws` workflow](../../../step-registry/firewatch/ipi/aws/firewatch-ipi-aws-workflow.yaml) will fail.

- rhscl-deploy-and-test ref will use 'rhscl' as the default value.


### Custom Images

- `rhscl-runner`
  - [Dockerfile](https://github.com/sclorg/ansible-tests/blob/master/Dockerfile)
  - The custom image for this step uses the [`Ansible Automation Platform compatibility execution environment`](registry.redhat.io/ansible-automation-platform/ee-29-rhel8:latest) image as it's base. The image should have all of the required dependencies installed and the [sclorg/ansible-tests repository](https://github.com/sclorg/ansible-tests) copied into `/tmp/tests/ansible-tests`.


