# opp-app-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To deploy a basic application that uses all components of the OPP product suite improving testing for interoperability.

## Process

- Set two dynamic variables based on the ephemeral hub cluster that needs to be provisioned prior to running this.
- Runs a script that deploys an application using ACM.  The image is added into the Quay registry, backed by ODF.  The registry and the application are scanned by ACS.  This provides a single application that can be a point of interop testing for all of the products.

## Requirements

- Deploy an application that can be used in Interop tests across the OPP products.

### Infrastructure

- A provisioned test cluster to target (hub).
- "advanced-cluster-management" operator installed (see [`install-operators`](../../../step-registry/install-operators/README.md)).
- MCH custom resource installed (see [acm-mch step](../mch/README.md))
- [acm-policies-openshift-plus-commands.sh](../policies/openshift-plus/acm-policies-openshift-plus-commands.sh) needs to successfully have run prior to this running. This is what installs the OPP operators.

### Environment Variables

