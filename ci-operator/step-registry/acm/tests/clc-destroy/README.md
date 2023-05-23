# acm-tests-clc-destroy-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To delete the clusters created by the step [acm-tests-clc-create-ref](../clc-create/README.md).

> **IMPORTANT**
> This meant to be used as a post task. Please do not use the clc-create ref without also using this ref.

## Process

- This ref is using the same code as the clc-create-ref with one exception. We have one additional environment var that we are defaulting to `TEST_STAGE: OCPInterop-destroy`. This will instruct tue start-test.sh script to destroy cluster rather then create. This env var can be overwritten in your config if you want to use a different value.
- Copies a secret file needed for test into env.
- Sets three dynamic variables based on the ephemeral hub cluster that needs to be provisioned prior to running this.
- Runs a [script from product QE's repo](https://github.com/stolostron/clc-ui-e2e/blob/main/execute_clc_interop_commands.sh) that does some additional config and ultimately runs the  script ([start-tests.sh](https://github.com/stolostron/clc-ui-e2e/blob/main/start-tests.sh)) to kick off a cypress test where we destroy the managed-clusters created earlier using the clc-create-ref.

## Requirements


### Infrastructure

- A provisioned test cluster to target (hub).
- "advanced-cluster-management" operator installed (see [`install-operators`](../../../step-registry/install-operators/README.md)).
- MCH custom resource installed (see [acm-mch step](../mch/README.md))
- [acm-tests-clc-create-commands.sh](../tests/clc-create/acm-tests-clc-create-commands.sh) needs to successfully have run prior to this running. This is what creates the managed clusters that are being used to gather data from.

### Environment Variables

- Please see [acm-tests-clc-destroy-ref.yaml](acm-tests-clc-destroy-ref.yaml) env section.