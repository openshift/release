# oadp-ipi-aws-workflow<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)

## Purpose

The `firewatch-cucushift-installer-rehearse-aws-ipi` workflow is essentially a copy of the `cucushift-installer-rehearse-aws-ipi` workflow with an additional `post` step used to report Jira issues for failed OpenShift CI jobs. Please see the [CSPI-QE/firewatch](https://github.com/CSPI-QE/firewatch) repository for more documentation on the firewatch tool.

## Process

The additional step(s) used in this workflow are as follows:

- **post steps**
  - [`firewatch-report-issues`](https://steps.ci.openshift.org/reference/firewatch-report-issues)

Please see the [`cucushift-installer-rehearse-aws-ipi`](https://steps.ci.openshift.org/workflow/cucushift-installer-rehearse-aws-ipi) documentation for more information regarding the steps that are not either of the steps explained above as they are not maintained by the CSPI QE team.