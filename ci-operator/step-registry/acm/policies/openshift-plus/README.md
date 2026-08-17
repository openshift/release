# acm-policies-openshift-plus-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Other](#other)

## Purpose

Once the [openshift-plus-setup](https://github.com/stolostron/policy-collection/tree/main/policygenerator/policy-sets/community/openshift-plus-setup) policy set has been applied this ref can be used to deploy [openshift-plus](https://github.com/stolostron/policy-collection/tree/main/policygenerator/policy-sets/stable/openshift-plus) using the policy set.

## Process

1. Clone the policy-collection repo.
2. Deploy openshift-plus policy set using gitops.
3. Waits for all policies to become compliant before proceeding.

## Requirements

### Infrastructure

- A provisioned test cluster to target.
  - The `advanced-cluster-management operator` installed (See [install-operators](../../../install-operators/README.md)).
  - [MCH deployed](../../mch/README.md).
  - [acm/policies/openshift-plus-setup](../openshift-plus-setup/README.md) ref executed prior to this ref (it will do things like deploy storage nodes to prepare for ODF).

### Other
