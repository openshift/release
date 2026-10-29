# mtc-qe-mtc-e2e-qev2-master<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning - `firewatch-cluster`](#cluster-provisioning-and-deprovisioning---firewatch-cluster)
  - [Test Setup, Execution, and Reporting Results - `mtc-interop-aws`](#test-setup-execution-and-reporting-results---mtc-interop-aws)
- [Prerequisite(s)](#prerequisites)
  - [Environment Variables](#environment-variables)
  - [Custom Images](#custom-images)

## General Information

> **NOTE:**
> 
> The repositories used are mirrored from the RedHat GitLab instance to GitHub.

- **Repositories Used**:
  - [mtc-qe/mtc-e2e-qev2](https://github.com/mtc-qe/mtc-e2e-qev2)
  - [mtc-qe/mtc-apps-deployer](https://github.com/mtc-qe/mtc-apps-deployer)
  - [mtc-qe/mtc-interop](https://github.com/mtc-qe/mtc-interop)
  - [mtc-qe/mtc-python-client](https://github.com/mtc-qe/mtc-python-client)
- **Operator Tested**: [MTC (Migration Toolkit for Containers)](https://docs.openshift.com/container-platform/4.13/welcome/index.html)

## Purpose

To provision the necessary infrastructure and use that infrastructure to execute MTC interop tests. The results of these tests will be reported to the appropriate sources following execution.

## Process

### Cluster Provisioning and Deprovisioning - `firewatch-cluster`

The `firewatch-cluster-workflow` workflow is essentially a copy of the [`cluster` workflow](../../../step-registry/cluster/cluster-workflow.yaml) with an additional `post` step used to report Jira issues for failed OpenShift CI jobs. Please see the [CSPI-QE/firewatch](https://github.com/CSPI-QE/firewatch) repository for more documentation on the firewatch tool.

The additional step used is [`firewatch-report-issues`](../../../step-registry/firewatch/report-issues/firewatch-report-issues-ref.yaml).


### Test Setup, Execution, and Reporting Results - `mtc-interop-aws`

1. [`mtc-prepare-clusters`](../../../step-registry/mtc/prepare-clusters/README.md)
2. [`mtc-execute-tests`](../../../step-registry/mtc/execute-tests/README.md)

## Prerequisite(s)

### Environment Variables

> **NOTE:**
> 
> Please notice that the `version` value defined in the `CLUSTER1_CONFIG` and the `CLUSTER2_CONFIG` variables are different. This operator is meant to transfer applications from a cluster running an older version of OCP to a cluster running a newer version of OCP. It is currently configured to run v4.1x on the source and 4.1x+1 on he target (i.e. source = 4.13 and target = 4.14).

- `CLUSTER1_CONFIG`
  - **Definition**: Defines one of the two clusters required (source cluster). Used by the [`cluster-install` ref](../../../step-registry/cluster/install/cluster-install-ref.yaml).
  - **If left empty**: The source cluster will not be provisioned prior to test execution.
- `CLUSTER2_CONFIG`
  - **Definition**: Defines one of the two clusters required (target cluster). Used by the [`cluster-install` ref](../../../step-registry/cluster/install/cluster-install-ref.yaml).
  - **If left empty**: The target cluster will not be provisioned prior to test execution.
- `FIREWATCH_CONFIG`
  - **Definition**: Defines a list of rules for the [`firewatch-report-issues` ref](../../../step-registry/firewatch/report-issues/firewatch-report-issues-ref.yaml). Please see [firewatch documentation](https://github.com/CSPI-QE/firewatch/blob/main/docs/configuration_guide.md) for more information.
  - **If left empty**: The [`firewatch-report-issues` ref](../../../step-registry/firewatch/report-issues/firewatch-report-issues-ref.yaml) will fail.
- `FIREWATCH_DEFAULT_JIRA_PROJECT`
  - **Definition**: Defines the Jira project that firewatch will report bugs to if a failure does not match a rule defined in the `FIREWATCH_CONFIG` variable.
  - **If left empty**: The [`firewatch-report-issues` ref](../../../step-registry/firewatch/report-issues/firewatch-report-issues-ref.yaml) will fail.
- `FIREWATCH_JIRA_SERVER`
  - **Definition**: Defines the Jira server URL that the [`firewatch-report-issues` ref](../../../step-registry/firewatch/report-issues/firewatch-report-issues-ref.yaml) will report bugs to.
  - **If left empty**: The [`firewatch-report-issues` ref](../../../step-registry/firewatch/report-issues/firewatch-report-issues-ref.yaml) will fail.
- `MTC_VERSION`
  - **Definition**: Defines the version of MTC to install on the source and target clusters. Example: `1.8`.
  - **If left empty**: The [`mtc-prepare-clusters` ref](../../../step-registry/mtc/prepare-clusters/README.md) will fail.
- `PULL_SECRET_NAME`
  - **Definition**: Defines the name of the vault secret used containing the OCP pull secret. Used by the [`cluster-install` ref](../../../step-registry/cluster/install/cluster-install-ref.yaml).
  - **If left empty**: The [`cluster-install` ref](../../../step-registry/cluster/install/cluster-install-ref.yaml) will fail.
- `S3_BUCKET_NAME`
  - **Definition**: Defines the name of the S3 bucket used to store cluster information. Used by the [`cluster-install` ref](../../../step-registry/cluster/install/cluster-install-ref.yaml).
  - **If left empty**: The [`cluster-install` ref](../../../step-registry/cluster/install/cluster-install-ref.yaml) will fail.
- `S3_BUCKET_PATH`
  - **Definition**: Defines the path within the `S3_BUCKET_NAME` to use to store cluster information. Used by the [`cluster-install` ref](../../../step-registry/cluster/install/cluster-install-ref.yaml).
  - **If left empty**: The [`cluster-install` ref](../../../step-registry/cluster/install/cluster-install-ref.yaml) will fail.

### Custom Images

- `mtc-runner`
  - [Dockerfile](https://github.com/mtc-qe/mtc-e2e-qev2/blob/master/dockerfiles/interop/Dockerfile)
  - This image is used to execute the MTC interop test suite. The image copies in the [mtc-qe/mtc-e2e-qev2](https://github.com/mtc-qe/mtc-e2e-qev2) repository as well as a tar archive of the [mtc-qe/mtc-python-client](https://github.com/mtc-qe/mtc-python-client) and [mtc-qe/mtc-apps-deployer](https://github.com/mtc-qe/mtc-apps-deployer) repositories. These repositories are required to execute the tests but are private. Because cloning them would require maintaining a service account, it has been decided to promote and image for each repository in OpenShift CI. The images of these repositories are basic and only really contain the tar archive of the respective repositories. Using the promoted images, we can just copy the archive out of each image and into the `mtc-runner` image.
- `mtc-inerop`
  - [Dockerfile](https://github.com/mtc-qe/mtc-interop/blob/master/Dockerfile)
  - This image is used to the the [`mtc-prepare-clusters` ref](../../../step-registry/mtc/prepare-clusters/README.md). It contains the [mtc-qe/mtc-interop](https://github.com/mtc-qe/mtc-interop) repository and all dependencies required to execute the Ansible playbooks to prepare the two clusters used in this scenario.
  