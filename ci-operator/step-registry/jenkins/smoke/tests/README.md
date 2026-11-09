# jenkins-smoke-tests-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)
  - [Other](#other)
- [Custom Image - `jenkins-runner`](#custom-image---jenkins-runner)

## Purpose

Used to execute `make smoke` [jenkins-smoke-tests](https://github.com/openshift/jenkins) using the provided arguments.

## Process

1. Executes make smoke to deploy and test. 
2. Copies the XML results and log files produced from the command in step 1 to `$ARTIFACT_DIR/out

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.

### Environment Variables

- `KUBECONFIG`
  - **Definition**: Path and name of kubeconfig file of cluster.
  - **If left empty**: This step will fail

### Other


## Custom Image - `jenkins-runner`

- `jenkins-runner`
  - [Dockerfile](Inline)
  - The image should have all of the required dependencies installed and the [openshift/jenkins repository](https://github.com/openshift/jenkins) copied to it.


