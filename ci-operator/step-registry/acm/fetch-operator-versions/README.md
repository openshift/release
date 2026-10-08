# acm-fetch-operator-versions-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To gather information about the OPP operators that are being tested for interoperability.

## Process

- Set two dynamic variables based on the ephemeral hub cluster that needs to be provisioned prior to running this.
- Runs a script that collects the versions of operators being tested for OPP interoperability.  The latest versions of most of the operators are installed so we need to collect what versions have been tested.

## Requirements

- Document the versions of the OPP operators that are tested.

### Infrastructure

- A provisioned test cluster to target (hub).
- "advanced-cluster-management" operator installed (see [`install-operators`](../../../step-registry/install-operators/README.md)).
- MCH custom resource installed (see [acm-mch step](../mch/README.md))
- [acm-policies-openshift-plus-commands.sh](../policies/openshift-plus/acm-policies-openshift-plus-commands.sh) needs to successfully have run prior to this running. This is what installs the OPP operators.

### Environment Variables

