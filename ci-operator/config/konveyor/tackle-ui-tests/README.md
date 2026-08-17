# konveyor-tackle-ui-tests<!-- omit from toc -->

## Table of Contents <!-- omit from toc -->

- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`](#cluster-provisioning-and-deprovisioning-firewatch-ipi-aws)
  - [Test Setup, Execution, and Reporting Results: `mta-interop-aws`](#test-setup-execution-and-reporting-results-mta-interop-aws)
- [Prerequisite(s)](#prerequisites)
  - [Environment Variables](#environment-variables)
  - [Custom Images](#custom-images)

## General Information

- **Repository**: [konveyor/tackle-ui-tests](https://github.com/konveyor/tackle-ui-tests)
- **Operator Tested**: [MTA (Migration Toolkit for Applications)](https://developers.redhat.com/products/mta/getting-started)

## Purpose

To provision the necessary infrastructure and using that infrastructure to execute MTA interop tests. The results of these tests will be reported to the appropriate sources following execution.

## Process

The MTA Interop scenario can be broken into the following basic steps:

1. Provision a test cluster on AWS
2. Install the MTA operator and deploy Tackle
3. Execute tests and archive results
4. Deprovision the test cluster
5. Execute the [Firewatch tool](https://github.com/CSPI-QE/firewatch) to report any failures to Jira

### Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`

The [`firewatch-ipi-aws` workflow](../../../step-registry/firewatch/ipi/aws/firewatch-ipi-aws-workflow.yaml) is just an extension of the [`ipi-aws` workflow](../../../step-registry/ipi/aws/ipi-aws-workflow.yaml) with the addition of executing the [Firewatch tool](https://github.com/CSPI-QE/firewatch) for Jira purposes.

Please see the [`ipi-aws`](https://steps.ci.openshift.org/workflow/ipi-aws) documentation for more information on this workflow. This workflow is not maintained by the Interop QE team.

### Test Setup, Execution, and Reporting Results: `mta-interop-aws`

Following the test cluster being provisioned, the following steps are executed in this order:

1. [`install-operators`](../../../step-registry/install-operators/README.md)
2. [`mta-deploy-takcle-ref`](../../../step-registry/mta/deploy-tackle/README.md)
3. [`mta-tests-ui-ref`](../../../step-registry/mta/tests/ui/README.md)

## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
  - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
  - **If left empty**: The [`ipi-aws` workflow](../../../step-registry/ipi/aws/ipi-aws-workflow.yaml) will fail.
- `FIREWATCH_CONFIG`
  - **Definition**: A JSON list of Firewatch configuration rules. Please see the [Firewatch Documentation](https://github.com/CSPI-QE/firewatch/blob/main/docs/cli_usage_guide.md#configuration) for more information.
  - **If left empty**: The Firewatch execution will encounter an error.
- `FIREWATCH_DEFAULT_JIRA_PROJECT`
  - **Definition**: The default Jira project that Firewatch uses to file bugs in if a failure is found that doesn't match a rule defined in the `FIREWATCH_CONFIG` list.
  - **If left empty**: The Firewatch execution will encounter an error.
- `FIREWATCH_JIRA_SERVER`
  - **Definition**: The Jira server that bugs should be filed to.
  - **If left empty**: The Red Hat stage Jira server will be used.
- `OPERATORS`
  - **Definition**: A JSON list of operators to install. Please see the [Defining `OPERATORS`](../../../step-registry/install-operators/README.md#defining-operators) section of the `install-operators` documentation for more information.
  - **If left empty**: The [`install-operators`](../../../step-registry/install-operators/README.md) ref will fail.

### Custom Images

- `mta-runner`
  - [Dockerfile](https://github.com/konveyor/tackle-ui-tests/blob/main/dockerfiles/interop/Dockerfile)
  - The customer image for this scenario uses the [`cypress/base`](https://hub.docker.com/r/cypress/base) image as it's base. The image should have all of the required dependencies installed and the [konveyor/tackle-ui-tests repository](https://github.com/konveyor/tackle-ui-tests) copied into `/tmp/tackle-ui-tests`