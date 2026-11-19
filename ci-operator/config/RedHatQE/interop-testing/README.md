# OpenShift Virtualization Interoperability Tests<!-- omit from toc -->

gi## Table of Contents<!-- omit from toc -->
- [General Information](#general-information)
- [Purpose](#purpose)
- [Test Scenarios](#test-scenarios)
  - [CNV+ODF Interop Tests](#cnvodf-interop-tests)
  - [IBM Fusion Access Operator Interop Tests](#ibm-fusion-access-operator-interop-tests)
  - [Goldman Sachs Configured Bare-Metal Cluster OpenShift Virtualization Tests](#goldman-sachs-configured-bare-metal-cluster-openshift-virtualization-tests)
  - [ACM+Virt Interop Tests](#acmvirt-interop-tests)
- [Process](#process)
    - [CNV+ODF Test Execution](#cnvodf-test-execution)
    - [ACM+Virt Test Execution](#acmvirt-test-execution)
- [Prerequisites](#prerequisites)
- [Test Configurations](#test-configurations)
  - [CNV+ODF Configurations](#cnvodf-configurations)
  - [IBM Fusion Access Operator Interop Tests](#ibm-fusion-access-operator-interop-tests-1)
    - [Test Chains](#test-chains)
  - [GS Bare-Metal Configurations](#gs-bare-metal-configurations)
  - [ACM+Virt Configurations](#acmvirt-configurations)

## General Information

- **Repositories:**
  -  [RedHatQE/interop-testing](https://github.com/RedHatQE/interop-testing)
  -  [RedHatQE/openshift-virtualization-tests](https://github.com/RedHatQE/openshift-virtualization-tests) 

## Purpose

To provision the necessary infrastructure and execute OpenShift Virtualization interoperability tests for various operator combinations, configurations, and scenarios. The results of these tests will be reported to appropriate sources following execution.

## Test Scenarios

### CNV+ODF Interop Tests

The CNV+ODF Interop Tests verify the interoperability between OpenShift Virtualization (CNV) and OpenShift Data Foundation (ODF) operators.

### IBM Fusion Access Operator Interop Tests

The IBM Fusion Access Operator tests the integration of the Fusion Access Operator with OpenShift, including IBM Storage Scale deployment and AWS EBS filesystem integration.

### Goldman Sachs Configured Bare-Metal Cluster OpenShift Virtualization Tests 

Refer to [`gs-baremetal-localnet-test`](../../../step-registry/gs-baremetal/localnet-test/gs-baremetal-localnet-test-ref.yaml) and [`README`](../../../step-registry/gs-baremetal/localnet-test/README.md) to execute OpenShift Virtualization Networking tests on bare-metal cluster configured for Goldman Sachs

### ACM+Virt Interop Tests

ACM+Virt jobs exercise Advanced Cluster Management with OpenShift Virtualization. Cross-cluster live migration (CCLM) covers spoke-to-spoke and hub-to-spoke migration. The product-to-product and upgrade jobs install a spoke, ODF, and CNV, then upgrade and run ACM tests.

Step layout and ref names are in the [ACM CCLM step README](../../../step-registry/interop/acm/cclm/acm-virt-bundle/README.md).

## Process

#### CNV+ODF Test Execution

For cluster provisioning and de-provisioning, see the [`firewatch-ipi-aws`](https://steps.ci.openshift.org/workflow/firewatch-ipi-aws) documentation for more information on this workflow. This workflow is not maintained by the Interop QE team.

Following cluster provisioning, the following steps are executed in order:

1. [`deploy-odf`](../../../step-registry/interop-tests/deploy-odf/README.md) ([ref](../../../step-registry/interop-tests/deploy-odf/interop-tests-deploy-odf-ref.yaml)) - Deploy ODF operator and storage system
2. [`ocs-tests`](../../../step-registry/interop-tests/ocs-tests/README.md) ([ref](../../../step-registry/interop-tests/ocs-tests/interop-tests-ocs-tests-ref.yaml)) - Execute ODF storage tests
3. [`deploy-cnv`](../../../step-registry/interop-tests/deploy-cnv/README.md) ([ref](../../../step-registry/interop-tests/deploy-cnv/interop-tests-deploy-cnv-ref.yaml)) - Deploy CNV operator
4. [`cnv-tests-e2e-deploy`](../../../step-registry/interop-tests/cnv-tests-e2e-deploy/README.md) ([ref](../../../step-registry/interop-tests/cnv-tests-e2e-deploy/interop-tests-cnv-tests-e2e-deploy-ref.yaml)) - Execute CNV e2e tests
5. [`openshift-virtualization-tests`](../../../step-registry/interop-tests/openshift-virtualization-tests/README.md) ([ref](../../../step-registry/interop-tests/openshift-virtualization-tests/interop-tests-openshift-virtualization-tests-ref.yaml)) - Execute OpenShift Virtualization tests

#### ACM+Virt Test Execution

CCLM spoke-to-spoke (`cr--2spoke-mig--aws`) runs these steps after the hub is installed:

1. [`p2p-acm-mtv-integration`](../../../step-registry/p2p/acm-mtv-integration/p2p-acm-mtv-integration-ref.yaml) — hand MTV to ACM
2. [`acm-interop-p2p-cluster-install`](../../../step-registry/acm/interop-p2p/cluster-install/README.md) — provision spokes
3. [`p2p-acm-cnv-addon-install`](../../../step-registry/p2p/acm-cnv-addon-install/p2p-acm-cnv-addon-install-ref.yaml) — CNV on spokes
4. [`p2p-install-odf-spokes`](../../../step-registry/p2p/install-odf-spokes/p2p-install-odf-spokes-ref.yaml) — ODF on spokes
5. [`acm-interop-p2p-submariner-install`](../../../step-registry/acm/interop-p2p/submariner-install/acm-interop-p2p-submariner-install-chain.yaml) — Submariner
6. [`p2p-cnv-exchange-kubevirt-ca`](../../../step-registry/p2p/cnv-exchange-kubevirt-ca/p2p-cnv-exchange-kubevirt-ca-ref.yaml) — KubeVirt CA exchange
7. [`p2p-mtv-wait-acm-providers`](../../../step-registry/p2p/mtv-wait-acm-providers/p2p-mtv-wait-acm-providers-ref.yaml) — ACM MTV providers
8. [`p2p-mtv-create-migration-maps`](../../../step-registry/p2p/mtv-create-migration-maps/p2p-mtv-create-migration-maps-ref.yaml) and [`p2p-mtv-create-return-migration-maps`](../../../step-registry/p2p/mtv-create-return-migration-maps/p2p-mtv-create-return-migration-maps-ref.yaml)
9. [`p2p-cclm-bidir-migration-test`](../../../step-registry/p2p/cclm-bidir-migration-test/p2p-cclm-bidir-migration-test-chain.yaml) — bidirectional live migration. The execute and verify steps in that chain are the JUnit steps under [`acm-virt-bundle`](../../../step-registry/interop/acm/cclm/acm-virt-bundle/README.md).

Hub-spoke CCLM (`cr--hub-spoke-mig--aws`) uses the [`p2p-cclm-hub-spoke`](../../../step-registry/p2p/cclm-hub-spoke/p2p-cclm-hub-spoke-workflow.yaml) workflow. Its migration chain calls the hub-spoke JUnit steps in the same bundle. Post steps call [`acm-interop-p2p-cluster-uninstall`](../../../step-registry/acm/interop-p2p/cluster-uninstall/README.md).

The p2p and EUS jobs use `p2p-install-odf-hub`, spoke install, ODF spoke install, `p2p-acm-cnv-install-policy`, and spoke uninstall. Spoke OCP upgrade is `acm-interop-p2p-spoke-upgrade-prehealthcheck`, `acm-interop-p2p-spoke-upgrade`, then `acm-interop-p2p-spoke-upgrade-healthcheck`, followed by the ACM test steps.

## Prerequisites


## Test Configurations

### CNV+ODF Configurations

- **OCP 4.20**: 
    - `RedHatQE-interop-testing-master__cnv-odf-ocp-4.20-lp-interop.yaml`
    - `RedHatQE-interop-testing-master__cnv-odf-ocp-4.20-lp-interop-cr.yaml` (Component Readiness)
- **OCP 4.21**: `RedHatQE-interop-testing-master__cnv-odf-ocp-4.21-lp-interop-cr.yaml` (Component Readiness)

### IBM Fusion Access Operator Interop Tests

- `fusion-access-operator-ocp4.20-lp-interop`: Tests Fusion Access Operator with IBM Storage Scale on OpenShift 4.20
- `fusion-access-cnv-ocp4.20-lp-interop`: Tests Fusion Access Operator with CNV (OpenShift Virtualization) integration on OpenShift 4.20

#### Test Chains

The tests use modular chains for different testing scenarios:

1. **Environment Setup Chain** ([`interop-tests-ibm-fusion-access-environment-setup-chain`](../../../step-registry/interop-tests/ibm-fusion-access/environment-setup-chain/)) - Sets up namespaces, operators, and IBM Storage Scale cluster
2. **EBS Integration Chain** ([`interop-tests-ibm-fusion-access-ebs-integration-chain`](../../../step-registry/interop-tests/ibm-fusion-access/ebs-integration-chain/)) - Creates and tests EBS-backed IBM Storage Scale filesystems

For detailed documentation on individual steps and configuration options, see the [ibm-fusion-access step registry](../../../step-registry/ibm-fusion-access/).

### GS Bare-Metal Configurations
   
- **OCP 4.19**: `RedHatQE-interop-testing-master__gs-baremetal-localnet-ocp4.19-lp-gs.yaml`
    - Runs on existing Goldman Sachs bare-metal cluster
    - Uses `external-cluster` workflow
    - Tests OpenShift Virtualization localnet networking with single NIC configuration

### ACM+Virt Configurations

- **OCP 4.22 CCLM**: `RedHatQE-interop-testing-master__ocp-4.22-lpMainline-lp-interop--acm-virt--cclm.yaml`
    - `cr--2spoke-mig--aws` — spoke-to-spoke bidirectional CCLM
    - `cr--hub-spoke-mig--aws` — hub-spoke CCLM via `p2p-cclm-hub-spoke`
- **OCP 4.22 p2p**: `RedHatQE-interop-testing-master__ocp-4.22-lpMainline-lp-interop--acm-virt--p2p.yaml`
- **OCP 4.22 EUS upgrade from 4.20**: `RedHatQE-interop-testing-master__ocp-4.22-lpMainline-lp-interop--acm-virt--eus-upgrade-from-4.20.yaml`
- **OCP 5.0 p2p**: `RedHatQE-interop-testing-master__ocp-5.0-lpMainline-lp-interop--acm-virt--p2p.yaml`
- **OCP 4.21 ACM+CNV p2p**: `RedHatQE-interop-testing-master__acm-cnv-ocp-4.21-p2p.yaml`
