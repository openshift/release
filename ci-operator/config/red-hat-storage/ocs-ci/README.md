# Openshift ODF Interop Interoperability Tests<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`](#cluster-provisioning-and-deprovisioning-firewatch-ipi-aws)
  - [Test Setup, Execution, and Reporting Results - Openshift GitOps-interop-aws](#test-setup-execution-and-reporting-results---openshift-gitops-interop-aws)
    - [AWS Cluster configuration](#aws-cluster-configuration)
- [Prerequisite(s)](#prerequisites)
  - [Environment Variables](#environment-variables)

## General Information

- **Repository**: [RedHatStorage/ocs-ci](https://github.com/red-hat-storage/ocs-ci)
- **Operator Tested**: [OCS-CI](https://ocs-ci.readthedocs.io/en/latest/)
- **Maintainers**: RedHatStorage

## Purpose

To provision the necessary infrastructure and using that infrastructure to execute Openshift ODF interop tests.
The results of these tests will be reported to the appropriate sources following execution.

## Process

The Openshift ODF Interop scenario can be broken into the following basic steps:

1. Provision a test cluster on AWS
2. Select and label worker nodes for ODF
2. Install the ODF operator on the `openshift-storage` namespace
3. Setup StorageCluster for ODF named `ocs-storagecluster`
3. Execute tests and archive results
4. Deprovision a test cluster.

### Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`

Please see the [`firewatch-ipi-aws`](https://steps.ci.openshift.org/workflow/firewatch-ipi-aws) documentation for more information on this workflow. This workflow is not maintained by the Interop QE team.

### Test Setup, Execution, and Reporting Results

#### AWS Cluster configuration

For ODF, we are required to use these specifications: 

- `COMPUTE_NODE_TYPE`: m5.4xlarge 
- `ZONES_COUNT`: 3

Following the test cluster being provisioned, the following steps are executed in this order:

1. [`odf-prepare-cluster`](../../../step-registry/odf/prepare-cluster/odf-prepare-cluster-ref.yaml)
1. [`install-operators`](../../../step-registry/install-operators/README.md )
1. [`odf-apply-storage-cluster`](../../../step-registry/odf/apply-storage-cluster/odf-apply-storage-cluster-ref.yaml)
1. [`interop-tests-ocs-tests`](../../../step-registry/interop-tests/ocs-tests/interop-tests-ocs-tests-ref.yaml)

When the job finish we collect all Junit test outputs into Artifact dir, clean temporary tests-related files.

The test results will be reported into the both `OCSQE` Jira Project and a public Slack channel `odf-ocp-ci-results`

## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
  - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
  - **If left empty**: The `firewatch-ipi-aws` workflow will fail.
- `ODF_VERSION_MAJOR_MINOR`
  - **Definition**: The odf major.minor version
  - **Default value**: Is `4.13`.




