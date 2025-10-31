# OpenShift Interop Testing<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [General Information](#general-information)
- [Purpose](#purpose)
- [Test Scenarios](#test-scenarios)
  - [CNV+ODF Interop Tests](#cnvodf-interop-tests)
  - [Fusion Access Operator Interop Tests](#fusion-access-operator-interop-tests)
  - [OCP Networking Tests on Bare-Metal Cluster configured for Goldman Sachs](#ocp-networking-tests-on-bare-metal-cluster-configured-for-goldman-sachs)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`](#cluster-provisioning-and-deprovisioning-firewatch-ipi-aws)
  - [Test Execution Workflows](#test-execution-workflows)
    - [CNV+ODF Test Execution](#cnvodf-test-execution)
    - [Fusion Access Operator Test Execution](#fusion-access-operator-test-execution)
    - [Fusion Access Operator Individual Steps](#fusion-access-operator-individual-steps)
- [Prerequisites](#prerequisites)
  - [Environment Variables](#environment-variables)
    - [Common Variables](#common-variables)
    - [CNV+ODF Specific Variables](#cnvodf-specific-variables)
    - [Fusion Access Operator Specific Variables](#fusion-access-operator-specific-variables)
    - [Firewatch Configuration Variables](#firewatch-configuration-variables)
- [Test Configurations](#test-configurations)
  - [CNV+ODF Configurations](#cnvodf-configurations)
  - [Fusion Access Operator Configurations](#fusion-access-operator-configurations)

## General Information

- **Repository**: [RedHatQE/interop-testing](https://github.com/RedHatQE/interop-testing)
- **Maintained by**: Red Hat QE Interop Team
- **Test Infrastructure**: AWS CSPI QE cluster profile

## Purpose

To provision the necessary infrastructure and execute OpenShift interoperability tests for various operator combinations and scenarios. The results of these tests are reported to appropriate sources following execution.

## Test Scenarios

### CNV+ODF Interop Tests

Tests the interoperability between Containerized Data Virtualization (CNV) and OpenShift Data Foundation (ODF) operators.

**Supported Versions:**
- OCP 4.18, 4.19, 4.20
- CNV 4.18+
- ODF 4.18+

**Test Flow:**
1. Provision a test cluster on AWS
2. Install the ODF and CNV Operators
3. Setup ODF StorageSystem and use it as the default StorageClass for CNV
4. Execute CNV tests with ODF storage backend
5. Execute OpenShift Virtualization tests
6. Archive results and deprovision cluster

### Fusion Access Operator Interop Tests

Tests the IBM Fusion Access Operator integration with OpenShift, including IBM Storage Scale deployment and EBS filesystem integration.

**Supported Versions:**
- OCP 4.20
- Fusion Access Operator latest
- IBM Storage Scale v5.2.3.1

**Test Flow:**
1. Provision test cluster on AWS (via ipi-aws-pre chain)
2. **Environment Setup Chain**: Configure AWS security groups, install Fusion Access Operator, deploy IBM Storage Scale cluster
3. **EBS Integration Chain**: Create and attach EBS volumes, create LocalDisk resources, create and verify EBS filesystem
4. **CNV Test Chain**: Deploy CNV, create shared filesystem, configure and test CNV shared storage integration
5. Collect custom IBM must-gather (post-step)
6. Deprovision cluster and archive results (via ipi-aws-post chain)

### OCP Networking Tests on Bare-Metal Cluster configured for Goldman Sachs

Refer to [`openshift-virtualization-tests`](../../../step-registry/interop-tests/cnv-tests-gs-baremetal/localnet/interop-tests-cnv-tests-gs-baremetal-localnet-ref.yaml) and [`README`](../../../step-registry/interop-tests/cnv-tests-gs-baremetal/localnet/README.md)] - Execute OpenShift Virtualization Networking tests on bare-metal cluster for Goldman Sachs


## Process

### Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`

Please see the [`firewatch-ipi-aws`](https://steps.ci.openshift.org/workflow/firewatch-ipi-aws) documentation for more information on this workflow. This workflow is not maintained by the Interop QE team.

### Test Execution Workflows

#### CNV+ODF Test Execution

Following cluster provisioning, the following steps are executed in order:

1. [`deploy-odf`](../../../step-registry/interop-tests/deploy-odf/interop-tests-deploy-odf-ref.yaml) - Deploy ODF operator and storage system
2. [`ocs-tests`](../../../step-registry/interop-tests/ocs-tests/interop-tests-ocs-tests-ref.yaml) - Execute ODF storage tests
3. [`deploy-cnv`](../../../step-registry/interop-tests/deploy-cnv/interop-tests-deploy-cnv-ref.yaml) - Deploy CNV operator
4. [`cnv-tests-e2e-deploy`](../../../step-registry/interop-tests/cnv-tests-e2e-deploy/interop-tests-cnv-tests-e2e-deploy-ref.yaml) - Execute CNV e2e tests
5. [`openshift-virtualization-tests`](../../../step-registry/interop-tests/openshift-virtualization-tests/interop-tests-openshift-virtualization-tests-ref.yaml) - Execute OpenShift Virtualization tests

#### Fusion Access Operator Test Execution

The Fusion Access Operator tests follow a modular chain architecture with three main chains:

1. **Environment Setup Chain** - [`interop-tests-fusion-access-environment-setup-chain`](../../../step-registry/interop-tests/fusion-access/environment-setup-chain/interop-tests-fusion-access-environment-setup-chain-chain.yaml)
   - Core deployment infrastructure
   - Namespace creation, pull secrets, and security group configuration
   - Fusion Access Operator and FusionAccess resource installation
   - Node preparation and IBM Storage Scale cluster creation

2. **EBS Integration Chain** - [`interop-tests-fusion-access-ebs-integration-chain`](../../../step-registry/interop-tests/fusion-access/ebs-integration-chain/interop-tests-fusion-access-ebs-integration-chain-chain.yaml)
   - EBS volume creation and attachment
   - LocalDisk resource creation
   - IBM Storage Scale filesystem creation with EBS volumes
   - Filesystem and cluster verification

3. **CNV Test Chain** - [`interop-tests-fusion-access-cnv-test-chain`](../../../step-registry/interop-tests/fusion-access/cnv-test-chain/interop-tests-fusion-access-cnv-test-chain-chain.yaml)
   - CNV (OpenShift Virtualization) deployment
   - Shared filesystem creation for CNV integration
   - CNV shared storage configuration and testing
   - Data sharing verification between CNV and Fusion Access

4. **Post-Test Collection** - [`interop-tests-fusion-access-custom-ibm-must-gather`](../../../step-registry/interop-tests/fusion-access/custom-ibm-must-gather/interop-tests-fusion-access-custom-ibm-must-gather-ref.yaml)
   - Collect IBM Storage Scale must-gather for debugging
   - Run as post-step with `best_effort: true`

#### Fusion Access Operator Individual Steps

The Fusion Access Operator test execution includes the following individual steps that can be referenced:

**Core Deployment Steps:**
- [`interop-tests-fusion-access-create-namespaces`](../../../step-registry/interop-tests/fusion-access/create-namespaces/interop-tests-fusion-access-create-namespaces-ref.yaml) - Create required namespaces
- [`interop-tests-fusion-access-create-pull-secrets`](../../../step-registry/interop-tests/fusion-access/create-pull-secrets/interop-tests-fusion-access-create-pull-secrets-ref.yaml) - Create pull secrets for IBM images
- [`interop-tests-fusion-access-install-fusion-access-operator`](../../../step-registry/interop-tests/fusion-access/install-fusion-access-operator/interop-tests-fusion-access-install-fusion-access-operator-ref.yaml) - Install Fusion Access Operator
- [`interop-tests-fusion-access-create-fusionaccess-resource`](../../../step-registry/interop-tests/fusion-access/create-fusionaccess-resource/interop-tests-fusion-access-create-fusionaccess-resource-ref.yaml) - Create FusionAccess custom resource

**Storage Scale Deployment Steps:**
- [`interop-tests-fusion-access-check-crds`](../../../step-registry/interop-tests/fusion-access/check-crds/interop-tests-fusion-access-check-crds-ref.yaml) - Check for required CRDs
- [`interop-tests-fusion-access-check-nodes`](../../../step-registry/interop-tests/fusion-access/check-nodes/interop-tests-fusion-access-check-nodes-ref.yaml) - Check node readiness
- [`interop-tests-fusion-access-label-nodes`](../../../step-registry/interop-tests/fusion-access/label-nodes/interop-tests-fusion-access-label-nodes-ref.yaml) - Label nodes for Storage Scale
- [`interop-tests-fusion-access-configure-aws-security-groups`](../../../step-registry/interop-tests/fusion-access/configure-aws-security-groups/interop-tests-fusion-access-configure-aws-security-groups-ref.yaml) - Configure AWS security groups
- [`interop-tests-fusion-access-prepare-worker-nodes`](../../../step-registry/interop-tests/fusion-access/prepare-worker-nodes/interop-tests-fusion-access-prepare-worker-nodes-ref.yaml) - Prepare worker nodes for Storage Scale
- [`interop-tests-fusion-access-create-cluster`](../../../step-registry/interop-tests/fusion-access/create-cluster/interop-tests-fusion-access-create-cluster-ref.yaml) - Create IBM Storage Scale cluster

**EBS Filesystem Steps:**
- [`interop-tests-fusion-access-create-local-disks`](../../../step-registry/interop-tests/fusion-access/create-local-disks/interop-tests-fusion-access-create-local-disks-ref.yaml) - Create LocalDisk resources for EBS volumes
- [`interop-tests-fusion-access-create-ebs-filesystem`](../../../step-registry/interop-tests/fusion-access/create-ebs-filesystem/interop-tests-fusion-access-create-ebs-filesystem-ref.yaml) - Create EBS filesystem

**CNV Integration Steps:**
- [`interop-tests-fusion-access-create-shared-filesystem`](../../../step-registry/interop-tests/fusion-access/create-shared-filesystem/interop-tests-fusion-access-create-shared-filesystem-ref.yaml) - Create shared filesystem for CNV
- [`interop-tests-fusion-access-configure-cnv-shared-storage`](../../../step-registry/interop-tests/fusion-access/configure-cnv-shared-storage/interop-tests-fusion-access-configure-cnv-shared-storage-ref.yaml) - Configure CNV shared storage
- [`interop-tests-fusion-access-test-cnv-shared-storage`](../../../step-registry/interop-tests/fusion-access/test-cnv-shared-storage/interop-tests-fusion-access-test-cnv-shared-storage-ref.yaml) - Test CNV shared storage
- [`interop-tests-fusion-access-verify-shared-storage`](../../../step-registry/interop-tests/fusion-access/verify-shared-storage/interop-tests-fusion-access-verify-shared-storage-ref.yaml) - Verify shared storage functionality

## Prerequisites

### Environment Variables

#### Common Variables

- `BASE_DOMAIN`
  - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
  - **If left empty**: The [`firewatch-ipi-aws` workflow](../../../step-registry/ipi/aws/firewatch-ipi-aws-workflow.yaml) will fail.

#### CNV+ODF Specific Variables

- `OCP_VERSION` - OpenShift version (e.g., "4.18", "4.19", "4.20")
- `ODF_OPERATOR_CHANNEL` - ODF operator channel (e.g., "stable-4.18")
- `ODF_VERSION_MAJOR_MINOR` - ODF version (e.g., "4.18")
- `FIPS_ENABLED` - Enable FIPS mode ("true"/"false")

#### Fusion Access Operator Specific Variables

- `FUSION_ACCESS_NAMESPACE` - Namespace for Fusion Access Operator (default: "ibm-fusion-access")
- `FUSION_ACCESS_STORAGE_SCALE_VERSION` - IBM Storage Scale version (e.g., "v5.2.3.1")
- `STORAGE_SCALE_CLUSTER_NAME` - Name for the Storage Scale cluster (default: "ibm-spectrum-scale")
- `STORAGE_SCALE_CLIENT_CPU` - CPU resources for Storage Scale client (default: "2")
- `STORAGE_SCALE_CLIENT_MEMORY` - Memory resources for Storage Scale client (default: "4Gi")
- `STORAGE_SCALE_STORAGE_CPU` - CPU resources for Storage Scale storage (default: "2")
- `STORAGE_SCALE_STORAGE_MEMORY` - Memory resources for Storage Scale storage (default: "8Gi")
- `CUSTOM_SECURITY_GROUP_PORTS` - Custom security group ports (e.g., "12345,1191,60000-61000")
- `CUSTOM_SECURITY_GROUP_PROTOCOLS` - Custom security group protocols (e.g., "tcp,udp")
- `CUSTOM_SECURITY_GROUP_SOURCES` - Custom security group sources
- `IBM_ENTITLEMENT_KEY` - IBM entitlement key for accessing IBM images
- `FUSION_PULL_SECRET_EXTRA` - Additional pull secrets for IBM images

#### Firewatch Configuration Variables

- `FIREWATCH_CONFIG_FILE_PATH` - Path to Firewatch configuration file
- `FIREWATCH_DEFAULT_JIRA_ADDITIONAL_LABELS` - Additional JIRA labels for test failures
- `FIREWATCH_DEFAULT_JIRA_ASSIGNEE` - JIRA assignee for test failures
- `FIREWATCH_DEFAULT_JIRA_PROJECT` - JIRA project for test failures
- `FIREWATCH_FAIL_WITH_TEST_FAILURES` - Whether to fail on test failures ("true"/"false")
- `RE_TRIGGER_ON_FAILURE` - Whether to retrigger on failure ("true"/"false")

## Test Configurations

### CNV+ODF Configurations

- **OCP 4.18**: `RedHatQE-interop-testing-cnv-4.18__cnv-odf-ocp4.18-lp-interop.yaml`
  - Standard and FIPS variants
  - Monthly execution schedule
- **OCP 4.19**: `RedHatQE-interop-testing-master__cnv-odf-ocp4.19-lp-interop.yaml`
- **OCP 4.20**: `RedHatQE-interop-testing-master__cnv-odf-ocp-4.20-lp-interop.yaml`

### Fusion Access Operator Configurations

- **OCP 4.20**: `RedHatQE-interop-testing-master__fusion-access-operator-ocp4.20-lp-interop.yaml`
  - Weekly execution schedule (Mondays at 11 PM)
  - Custom security group configuration
  - IBM Storage Scale integration
