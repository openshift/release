# acm-tests-clc-smoke-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

Smoke-scoped variant of [acm-tests-clc-create](../clc-create/README.md) with a right-sized timeout and strict failure handling for OPP interop.

The full `acm-tests-clc-create` step already creates only 1 AWS managed cluster (~50 min actual runtime) but carries a 28800s (8h) timeout and suppresses failures with `|| :`. This step:
- Reduces the timeout to 5400s (90 min), giving ~80% headroom over the observed average.
- Runs with `best_effort: true` so independent downstream validations (ODF health, Quay smoke, observability) continue regardless of CLC outcome. The script still exits with the CLC status code for JUnit reporting and failure visibility.

> **IMPORTANT**
> You must use the [acm-tests-clc-destroy-ref](../clc-destroy/README.md) as a post step when using this step. If you do not and succeed in running this step then you will leave clusters running on the ACM QE team's cloud.

## Process

- Copies secret options file needed for test execution.
- Injects AWS credentials from the cluster profile into options.yaml.
- Sets dynamic variables based on the provisioned hub cluster.
- Runs `execute_clc_interop_commands.sh` which invokes Cypress with tag filter `@create+aws+-sno+-@clusterpool` (controlled by `TEST_STAGE=OCPInterop-create` inside the image).

## Requirements

### Infrastructure

- An existing OpenShift cluster to act as the target Hub.
- "advanced-cluster-management" operator installed (see [`install-operators`](../../../install-operators/README.md)).
- MCH custom resource installed (see [acm-mch step](../mch/README.md)).

### Environment Variables

- Please see [acm-tests-clc-smoke-ref.yaml](acm-tests-clc-smoke-ref.yaml) env section.
