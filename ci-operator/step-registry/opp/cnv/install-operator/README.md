# opp-cnv-install-operator-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Others](#others)

## Purpose

To install the OpenShift Virtualization(CNV) operator.


## Process

- Label the cluster with acm/cnv-operator-install: "true".
- Clone [mtv-integrations repo](https://github.com/stolostron/mtv-integrations.git).
- cd addons
- oc apply -f ./cnv-addon

## Requirements


### Infrastructure

- A provisioned test cluster to target.
  - The `advanced-cluster-management operator` installed (See [install-operators](../../../install-operators/README.md)).
  - [MCH deployed](../../../acm/mch/README.md).

### Others