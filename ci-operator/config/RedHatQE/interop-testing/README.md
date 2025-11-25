# OpenShift Virtualization Interop Testing<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [General Information](#general-information)
- [Purpose](#purpose)
- [Test Scenarios](#test-scenarios)
  - [CNV+ODF Interop Tests](#cnvodf-interop-tests)
  - [Goldman Sachs Configured Bare-Metal Cluster OpenShift Virtualization Tests](#goldman-sachs-configured-bare-metal-cluster-openshift-virtualization-tests)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`](#cluster-provisioning-and-deprovisioning-firewatch-ipi-aws)
  - [Test Execution Workflows](#test-execution-workflows)
    - [CNV+ODF Test Execution](#cnvodf-test-execution)
- [Prerequisites](#prerequisites)
  - [Environment Variables](#environment-variables)
    - [Common Variables](#common-variables)
    - [CNV+ODF Specific Variables](#cnvodf-specific-variables)
    - [Firewatch Configuration Variables](#firewatch-configuration-variables)
- [Test Configurations](#test-configurations)
  - [CNV+ODF Configurations](#cnvodf-configurations)

## General Information

- **CNV+ODF Repository**: [RedHatQE/interop-testing](https://github.com/RedHatQE/interop-testing)
  - **Repository Maintained by**: Red Hat QE Interop Team
  - **Test Infrastructure**: AWS CSPI QE cluster profile
- **Goldman Sachs Bare-Metal Test Repository**: [RedHatQE/openshift-virtualization-tests](https://github.com/RedHatQE/openshift-virtualization-tests) 

## Purpose

To provision the necessary infrastructure and execute OpenShift Virtualization interoperability tests for various operator combinations, configurations, and scenarios. The results of these tests are reported to appropriate sources following execution.

## Test Scenarios

### CNV+ODF Interop Tests

Tests the interoperability between OpenShift Virtualization (CNV) and OpenShift Data Foundation (ODF) operators.

**Supported Versions:**
- OCP 4.18+
- CNV 4.18+
- ODF 4.18+

**Test Flow:**
1. Provision a test cluster on AWS
2. Install the ODF and CNV Operators
3. Setup ODF StorageSystem and use it as the default StorageClass for CNV
4. Execute CNV tests with ODF storage backend
5. Execute OpenShift Virtualization tests
6. Archive results and deprovision cluster

### Goldman Sachs Configured Bare-Metal Cluster OpenShift Virtualization Tests 

Refer to [`gs-baremetal-localnet-test`](../../../step-registry/gs-baremetal/localnet-test/gs-baremetal-localnet-test-ref.yaml) and [`README`](../../../step-registry/gs-baremetal/localnet-test/README.md) to execute OpenShift Virtualization Networking tests on bare-metal cluster configured for Goldman Sachs


## Process

### Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`

Please see the [`firewatch-ipi-aws`](https://steps.ci.openshift.org/workflow/firewatch-ipi-aws) documentation for more information on this workflow. This workflow is not maintained by the Interop QE team.

### Test Execution Workflows

#### CNV+ODF Test Execution

Following cluster provisioning, the following steps are executed in order:

1. [`deploy-odf`](../../../step-registry/interop-tests/deploy-odf/README.md) ([ref](../../../step-registry/interop-tests/deploy-odf/interop-tests-deploy-odf-ref.yaml)) - Deploy ODF operator and storage system
2. [`ocs-tests`](../../../step-registry/interop-tests/ocs-tests/README.md) ([ref](../../../step-registry/interop-tests/ocs-tests/interop-tests-ocs-tests-ref.yaml)) - Execute ODF storage tests
3. [`deploy-cnv`](../../../step-registry/interop-tests/deploy-cnv/README.md) ([ref](../../../step-registry/interop-tests/deploy-cnv/interop-tests-deploy-cnv-ref.yaml)) - Deploy CNV operator
4. [`cnv-tests-e2e-deploy`](../../../step-registry/interop-tests/cnv-tests-e2e-deploy/README.md) ([ref](../../../step-registry/interop-tests/cnv-tests-e2e-deploy/interop-tests-cnv-tests-e2e-deploy-ref.yaml)) - Execute CNV e2e tests
5. [`openshift-virtualization-tests`](../../../step-registry/interop-tests/openshift-virtualization-tests/README.md) ([ref](../../../step-registry/interop-tests/openshift-virtualization-tests/interop-tests-openshift-virtualization-tests-ref.yaml)) - Execute OpenShift Virtualization tests
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

#### Firewatch Configuration Variables

- `FIREWATCH_CONFIG_FILE_PATH` - Path to Firewatch configuration file
- `FIREWATCH_DEFAULT_JIRA_ADDITIONAL_LABELS` - Additional JIRA labels for test failures
- `FIREWATCH_DEFAULT_JIRA_ASSIGNEE` - JIRA assignee for test failures
- `FIREWATCH_DEFAULT_JIRA_PROJECT` - JIRA project for test failures
- `FIREWATCH_FAIL_WITH_TEST_FAILURES` - Whether to fail on test failures ("true"/"false")
- `RE_TRIGGER_ON_FAILURE` - Whether to retrigger on failure ("true"/"false")

## Test Configurations
   ### GS Bare-Metal Configurations
   
- **OCP 4.19**: `RedHatQE-interop-testing-master__gs-baremetal-localnet-ocp4.19-lp-gs.yaml`
    - Runs on existing Goldman Sachs bare-metal cluster
    - Uses `external-cluster` workflow
    - Tests OpenShift Virtualization localnet networking with single NIC configuration
### CNV+ODF Configurations

- **OCP 4.18**: `RedHatQE-interop-testing-cnv-4.18__cnv-odf-ocp4.18-lp-interop.yaml`
    - Standard and FIPS variants
    - Monthly execution schedule
- **OCP 4.19**: `RedHatQE-interop-testing-master__cnv-odf-ocp4.19-lp-interop.yaml`
- **OCP 4.20**: 
    - `RedHatQE-interop-testing-master__cnv-odf-ocp-4.20-lp-interop.yaml`
    - `RedHatQE-interop-testing-master__cnv-odf-ocp-4.20-lp-interop-cr.yaml` (Component Readiness)
- **OCP 4.21**: `RedHatQE-interop-testing-master__cnv-odf-ocp-4.21-lp-interop-cr.yaml` (Component Readiness)
