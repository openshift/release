# acm-tests-alc-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To run the OBSERVABILITY interop tests defined in the step [acm-tests-alc-ref](../alc/README.md).


## Process

- This ref runs a [script from product QE's repo](https://github.com/stolostron/application-ui-test/blob/release-2.7/execute_alc_interop_commands.sh) that kicks off Cypress tests where we create, update and delete applications such as GitOps, APP, Helm etc.

## Requirements


### Infrastructure

- A provisioned test cluster to target (hub).
- "advanced-cluster-management" operator installed (see [`install-operators`](../../../step-registry/install-operators/README.md)).
- MCH custom resource installed (see [acm-mch step](../mch/README.md))
- [acm-tests-clc-create-commands.sh](../tests/clc/acm-tests-clc-create-commands.sh) needs to successfully have run prior to this running. This is what creates the managed clusters that are being used to gather data from.
- [acm-tests-fetch-managed-clusters-commands.sh](../tests/fetch-managed-clusters/acm-tests-fetch-managed-clusters-commands.sh) needs to successfully have run prior to this running. This is what fetches the managed clusters info that are being used to gather data from.

### Environment Variables

- Please see [acm-tests-alc-ref.yaml](acm-tests-alc-ref.yaml) env section.