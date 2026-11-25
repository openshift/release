# oadp-rosa-aws-sts-workflow<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)

## Purpose

The `oadp-rosa-aws-sts` workflow is essentially a copy of the `firewatch-rosa-aws-sts` workflow with additional steps to provision and deprovision an AWS S3 bucket required by the scenario.

## Process

The additional steps used in this workflow are as follows:

- **pre steps**
  - [`oadp-s3-create`](../../../step-registry/oadp/s3/create/README.md)
- **post steps**
  - [`oadp-s3-destroy`](../../../step-registry/oadp/s3/destroy/README.md)

Please see the [`firewatch-rosa-aws-sts`](https://steps.ci.openshift.org/workflow/firewatch-rosa-aws-sts) documentation for more information regarding the steps that are not either of the steps explained above as they are not maintained by the CSPI QE team.
