# inspector-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To run the ACM Inspector to collect details about the performance of the OPP installation.

## Process

- Set two dynamic variables based on the ephemeral hub cluster that needs to be provisioned prior to running this.
- Runs the ACM Inspector which is similar to a must-gather but focused on analysis more with regards to performance of the environment.

## Requirements

- Run the ACM Inspector and make results available.

### Infrastructure

- A provisioned test cluster to target (hub).
- "advanced-cluster-management" operator installed (see [`install-operators`](../../../step-registry/install-operators/README.md)).
- MCH custom resource installed (see [acm-mch step](../mch/README.md))
- [acm-policies-openshift-plus-commands.sh](../policies/openshift-plus/acm-policies-openshift-plus-commands.sh) needs to successfully have run prior to this running. This is what installs the OPP operators.

### Environment Variables

