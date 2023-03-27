# acm-tests-clc-create-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To test the managed cluster creation feature of ACM.
1 AWS managed cluster with 3 master/3 worker nodes will be created as part of this step using default variables.

> **IMPORTANT**
> You must use the [acm-tests-clc-destroy-ref](../clc-destroy/README.md) as a post step when using this clc-create-ref. If you do not and succeed in running the clc-create-ref then you will leave clusters running on the ACM QE team's cloud.

>Example usage in a config file
>```
>    post:
>    - ref: acm-tests-clc-destroy
>    test:
>    - ref: install-operators
>    - ref: acm-mch
>    - ref: acm-tests-clc-create
>```

## Process

- Copies a secret file needed for test into env.
- Sets three dynamic variables based on the ephemeral hub cluster that needs to be provisioned prior to running this.
- Runs a [script from product QE's repo](https://github.com/stolostron/clc-ui-e2e/blob/main/execute_clc_interop_commands.sh) that does some additional config and ultimately runs the  script ([start-tests.sh](https://github.com/stolostron/clc-ui-e2e/blob/main/start-tests.sh)) to kick off a cypress test where we install managed-clusters.

## Requirements


### Infrastructure

- An existing OpenShift cluster to act as the target Hub to deploy managed clusters onto.
- "advanced-cluster-management" operator installed (see [`install-operators`](../../../step-registry/install-operators/README.md)).
- MCH custom resource installed (see [acm-mch step](../mch/README.md))

### Environment Variables

- Please see [acm-tests-clc-create-ref.yaml](acm-tests-clc-create-ref.yaml) env section.