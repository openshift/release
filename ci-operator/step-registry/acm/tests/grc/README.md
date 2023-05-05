# acm-tests-grc-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To run the GRC interop tests defined in the step [acm-tests-grc-ref](../grc/README.md).


## Process

- This ref runs a [script from product QE's repo](https://github.com/stolostron/acmqe-grc-test/blob/release-2.7/execute_grc_interop_commands.sh) that does some additional config and ultimately runs the script ([run-docker-tests.sh](https://github.com/stolostron/acmqe-grc-test/blob/release-2.7/build/run-docker-tests.sh)) to kick off a cypress tests where we create and update GRC policies.

## Requirements


### Infrastructure

- A provisioned test cluster to target (hub).
- "advanced-cluster-management" operator installed (see [`install-operators`](../../../step-registry/install-operators/README.md)).
- MCH custom resource installed (see [acm-mch step](../mch/README.md))
- [acm-tests-clc-create-commands.sh](../tests/clc/acm-tests-clc-create-commands.sh) needs to successfully have run prior to this running. This is what creates the managed clusters that are being used to gather data from.
- [acm-tests-fetch-managed-clusters-commands.sh](../tests/fetch-managed-clusters/acm-tests-fetch-managed-clusters-commands.sh) needs to successfully have run prior to this running. This is what fetches the managed clusters info that are being used to gather data from.

### Environment Variables

- Please see [acm-tests-grc-ref.yaml](acm-tests-grc-ref.yaml) env section.