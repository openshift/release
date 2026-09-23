# stolostron-policy-collection<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [General Information](#general-information)
- [Purpose](#purpose)
  - [Cluster Provisioning and Deprovisioning:](#cluster-provisioning-and-deprovisioning)
- [Requirements](#requirements)
  - [Variables](#variables)
  - [Custom Images](#custom-images)

## General Information

- **Repository**: [stolostron/policy-collection](https://github.com/stolostron/policy-collection/tree/main)

## Purpose

Configs that use policies from the policy-collection repo to accomplish numerous different types of testing.

### Cluster Provisioning and Deprovisioning:

Please see the [`ipi-aws`](https://steps.ci.openshift.org/workflow/ipi-aws) documentation for more information on this workflow.

Other workflows deploying OCP on AWS can most likely be used here so far testing has just been done using the steps from the ipi-aws worfklow above.

## Requirements

### Variables

- `BASE_DOMAIN`
  - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
  - **If left empty**: The [`ipi-aws` workflow](../../../step-registry/ipi/aws/ipi-aws-workflow.yaml) will fail.\


### Custom Images
