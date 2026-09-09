# firewatch-cluster-workflow<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)

## Purpose

The `firewatch-cluster-workflow` workflow is essentially a copy of the `cluster` workflow with an additional `post` step used to report Jira issues for failed OpenShift CI jobs. Please see the [CSPI-QE/firewatch](https://github.com/CSPI-QE/firewatch) repository for more documentation on the firewatch tool.

## Process

The additional step(s) used in this workflow are as follows:

- **post steps**
  - [`firewatch-report-issues`](../../report-issues/firewatch-report-issues-ref.yaml)

Please see the [`cluster`](https://steps.ci.openshift.org/workflow/cluster) documentation for more information regarding the steps in this workflow.