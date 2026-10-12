# service-registry-run-tests-ref

## Table of Contents

- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
    - [Infrastructure](#infrastructure)
- [Custom Image](#custom-image)

## Purpose

Use to execute the `Java` [Apicurio/apicurio-registry-operator](https://github.com/Apicurio/apicurio-registry-operator/)
using the provided arguments. All XML results will be copied into `${ARTIFACT_DIR}/*.xml`.

## Process

1. Executes the Java tests using the following maven command:
```shell
FORCE_NAMESPACE=interop-test-namespace \
    REGISTRY_PACKAGE=service-registry-operator \
    REGISTRY_BUNDLE=./scripts/install.yaml \
    KAFKA_PACKAGE=amq-streams \
    KAFKA_DEPLOYMENT=amq-streams-cluster-operator \
    CATALOG=redhat-operators \
    mvn clean test -P interop
```
2. Copies the XML files from result dir to `${ARTIFACT_DIR}/*.xml`.

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.
- `KUBECONFIG` env variable set. This is done automatically by prow.

## Custom Image

- [apicurio/apicurio-ci-tools](https://quay.io/repository/apicurio/apicurio-ci-tools)
- To see Dockerfile, please contact someone from Service Registry QE.