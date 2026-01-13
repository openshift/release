# oadp-ipi-aws-workflow<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)

## Purpose

The `oadp-ipi-aws-oadp-qe-konflux` workflow is essentially a copy of the `ipi-aws` workflow with additional steps to provision and deprovision an AWS S3 bucket required by the scenario and deploy from iib. KONFLUX

## Process

The additional steps used in this workflow are as follows:

- **pre steps**
  - [`oadp-s3-create`](../../../step-registry/oadp/s3/create/README.md)
- **post steps**
  - [`oadp-s3-destroy`](../../../step-registry/oadp/s3/destroy/README.md)

Please see the [`ipi-aws`](https://steps.ci.openshift.org/workflow/ipi-aws) documentation for more information regarding the steps that are not either of the steps explained above as they are not maintained by the CSPI QE team.
