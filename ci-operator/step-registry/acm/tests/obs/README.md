# acm-tests-obs-create-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)

## Purpose

To run the ACM tests for the OBS ACM component.
This ref is meant to be re-usable so long as the requirements are met.

## Process

- Sets dynamic variables based on the ephemeral hub cluster that needs to be provisioned prior to running this.
- Runs a [script from product QE's repo](https://github.com/stolostron/observability_core_automation/blob/release-2.7/execute_obs_interop_commands.sh) that does some additional config and ultimately runs the tests.

## Requirements


### Infrastructure

- An existing OpenShift cluster to act as the target Hub to deploy managed clusters onto.
- "advanced-cluster-management" operator installed (see [`install-operators`](../../../step-registry/install-operators/README.md)).
- An existing managed cluster deployed by using the [clc-create ref](https://steps.ci.openshift.org/reference/acm-tests-clc-create).
- Stored knowledge of the managed cluster which can be gather by using the [fetch-managed-cluster ref](https://steps.ci.openshift.org/reference/acm-fetch-managed-clusters).