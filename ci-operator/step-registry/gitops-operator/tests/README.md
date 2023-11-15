# gitops-operator-tests-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

Use to execute the gitops-operator [sequential tests](https://github.com/redhat-developer/gitops-operator/tree/master/test/openshift/e2e/sequential) using the provided arguments. All XML results will be combined into "$ARTIFACT_DIR/junit_gitops-sequential.xml".

## Process

1. Runs the Operator tests from [sequential tests](https://github.com/redhat-developer/gitops-operator/tree/master/test/openshift/e2e/sequential) directory
2. Copies the XML file to `$ARTIFACT_DIR/junit_gitops-sequential.xml`

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.
  - Should have a `openshift-operators` namespace/project with:
    - The [`gitops-operator-operator`](../../install-operators/README.md) is installed.

### Environment Variables


- `BASE_DOMAIN`
  - **Definition**: BASE_DOMAIN value from the firewatch-ipi-aws workflow. This is used to built the target URL
  - **If left empty**: This step will fail