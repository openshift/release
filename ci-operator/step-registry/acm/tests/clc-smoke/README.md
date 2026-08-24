# acm-tests-clc-smoke-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)
- [Differences from acm-tests-clc-create](#differences-from-acm-tests-clc-create)

## Purpose

To test managed cluster creation feature of ACM with smoke-level scope for OPP interop validation.
Creates 1 AWS managed cluster using minimal test suite (filtered via `CUSTOMER_TAGS="@smoke"`).

**Designed for**: OPP interop pipelines that need managed cluster availability for downstream cross-product tests.

**Timeout**: 2 hours (vs 8 hours for full `acm-tests-clc-create` suite)

> **IMPORTANT**
> You must use the [acm-tests-clc-destroy-ref](../clc-destroy/README.md) as a post step when using this clc-smoke-ref. If you do not and succeed in running the clc-smoke-ref then you will leave clusters running on the ACM QE team's cloud.

>Example usage in a config file
>```
>    post:
>    - ref: acm-tests-clc-destroy
>    test:
>    - ref: install-operators
>    - ref: acm-mch
>    - ref: acm-tests-clc-smoke
>```

## Process

- Copies a secret file needed for test into env.
- Sets three dynamic variables based on the ephemeral hub cluster that needs to be provisioned prior to running this.
- Runs a [script from product QE's repo](https://github.com/stolostron/clc-ui-e2e/blob/main/execute_clc_interop_commands.sh) with `CUSTOMER_TAGS="@smoke"` filter.
- Creates 1 managed cluster (expected runtime: ~1.5h, timeout: 2h).

## Requirements

### Infrastructure

- An existing OpenShift cluster to act as the target Hub to deploy managed clusters onto.
- "advanced-cluster-management" operator installed (see [`install-operators`](../../../step-registry/install-operators/README.md)).
- MCH custom resource installed (see [acm-mch step](../mch/README.md))

### Environment Variables

- Please see [acm-tests-clc-smoke-ref.yaml](acm-tests-clc-smoke-ref.yaml) env section.
- **Key difference**: `CUSTOMER_TAGS` defaults to `"@smoke"` (vs empty string in full suite)

## Differences from acm-tests-clc-create

| Aspect | acm-tests-clc-create | acm-tests-clc-smoke |
|--------|---------------------|---------------------|
| **Timeout** | 28800s (8 hours) | 7200s (2 hours) |
| **Test Scope** | Full CLC suite | Smoke-level (`@smoke` tag) |
| **Purpose** | Comprehensive CLC testing | Interop smoke validation |
| **Runtime** | ~6-8 hours | ~1.5 hours |
| **CUSTOMER_TAGS** | "" (empty, runs all) | "@smoke" (filtered) |

**Use acm-tests-clc-smoke when**:
- You need managed cluster creation for interop validation
- You don't need full CLC lifecycle coverage (already tested in ACM CI)
- You want faster OPP job completion

**Use acm-tests-clc-create when**:
- You need comprehensive CLC test coverage
- You're testing CLC functionality itself
