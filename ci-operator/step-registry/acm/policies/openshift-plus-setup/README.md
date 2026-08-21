# acm-policies-openshift-plus-setup-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Other](#other)

## Purpose

Used to apply the [openshift-plus-setup](https://github.com/stolostron/policy-collection/tree/main/policygenerator/policy-sets/community/openshift-plus-setup) policy set to prepare for deploying [openshift-plus](https://github.com/stolostron/policy-collection/tree/main/policygenerator/policy-sets/stable/openshift-plus)
 - See [acm/policies/openshift-plus](../openshift-plus/README.md) ref. 

## Process

1. Create policies namespace.
2. Apply subscription admin policy.
3. Apply ManagedClusterSetBinding.
4. Clone the policy-collection repo.
5. Deploy openshift-plus-setup policy set using gitops.
6. Waits for storage nodes to come up before proceeding.

## Requirements

### Infrastructure

- A provisioned test cluster to target.
  - The `advanced-cluster-management operator` installed (See [install-operators](../../../install-operators/README.md)).
  - [MCH deployed](../../mch/README.md).

### Other
