# gitops-operator-tests-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

Use to execute the gitops-operator [parallel tests](https://github.com/redhat-developer/gitops-operator/tree/master/test/openshift/e2e/ginkgo/parallel) using the provided arguments. All XML results will be combined into "openshift-gitops-parallel-e2e.xml".

## Process

1. Runs the Operator tests from [parallel tests](https://github.com/redhat-developer/gitops-operator/tree/master/test/openshift/e2e/ginkgo/parallel) directory
2. Copies the XML file to `${ARTIFACT_DIR}/original_results/`

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.
  - Should have a `openshift-gitops-operator` namespace/project with:
    - The [`gitops-operator-operator`](../../install-operators/README.md) is installed.

### Environment Variables


- `BASE_DOMAIN`
  - **Definition**: BASE_DOMAIN value from the firewatch-ipi-aws workflow. This is used to built the target URL
  - **If left empty**: This step will fail