# 3scale-ipi-aws-workflow<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#purpose)

## Purpose

The `3scale-ipi-aws` workflow is essentially a copy of the `ipi-aws` workflow with 3scale API Manager uninstallation step specific to the 3scale interop scenario.

## Process

The additional steps used in this workflow are as follows:

- **post steps**
  - [`3scale-apimanager-uninstall`](../../../../step-registry/3scale/apimanager/uninstall/README.md)

Please see the [`ipi-aws`](https://steps.ci.openshift.org/workflow/ipi-aws) documentation for more information regarding the steps that are not either of the steps explained above as they are not maintained by the CSPI QE team.