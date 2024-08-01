# strimzi-run-tests-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
    - [Infrastructure](#infrastructure)
    - [Environment Variables](#environment-variables)
    - [Other](#other)
- [Custom Image - `strimzi-qe/strimzi-tests`](#custom-image)

## Purpose

Use to execute the `Java` [strimzi/strimzi-kafka-operator](https://github.com/strimzi/strimzi-kafka-operator) using the provided arguments.
All XML results will be copied into `$ARTIFACT_DIR/xunit/junit_*.xml`.
All logs could be found at `$ARTIFACT_DIR/logs/`.

## Process

1. Executes the Java tests using the following maven command:
```shell
mvn verify -pl systemtest -P all \
	-Dgroups="$GROUPS" \
	-DexcludedGroups="$EXCLUDED_GROUPS" \
	-Dmaven.repo.local=/tmp/m2 \
	-Dmaven.javadoc.skip=true \
	-Dfailsafe.rerunFailingTestsCount=1
```
2. Copies the XML files from result dir to `$ARTIFACT_DIR/xunit/junit_*.xml`.

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.
- `KUBECONFIG` env variable set. This is done automatically by prow.

### Environment Variables

- `CLUSTER_OPERATOR_INSTALL_TYPE`
    - **Definition**: Specify install type of AMQ Streams operator [`olm`, `bundle`, `helm`].
      - **If left empty**: It will use `olm` as default. This shouldn't be changed unless we will want to test different install type.
- `OLM_OPERATOR_CHANNEL`
  - **Definition**: Specify channel from operator source.
  - **If left empty**: It will use `stable` as default.
- `OLM_OPERATOR_NAME`
  - **Definition**: Specify operator name as it is released to index image bundle
  - **If left empty**: It will use `amq-streams` as default. This shouldn't be changed from default unless AMQ Streams operator will change the install policy or name.
- `OLM_SOURCE_NAME`
  - **Definition**: Specify operators source from where the operator will be installed.
  - **If left empty**: It will use `redhat-operators` as default.
- `OLM_APP_BUNDLE_PREFIX`
  - **Definition**: Specify operator app bundle prefix. This shouldn't be changed from default unless AMQ Streams operator will change the install policy or name.
  - **If left empty**: It will use `amqstreams` as default.
- `OLM_OPERATOR_DEPLOYMENT_NAME`
  - **Definition**: Specify operator deployment name. This shouldn't be changed from default unless AMQ Streams operator will change the install policy or name.
  - **If left empty**: It will use `amq-streams-cluster-operator` as default.
- `GROUPS`
  - **Definition**: Specify subset of tests that will be executed.
  - **If left empty**: It will use `sanity` as default.
- `EXCLUDED_GROUPS`
  - **Definition**: Specify subset of tests that will be excluded from execution. This shouldn't be changed.
  - **If left empty**: It will use `nodeport,loadbalancer` as default.
- `TEST_LOG_DIR`
  - **Definition**: Specify directory for gathered logs.
  - **If left empty**: It will use `systemtest/target/logs` as default. 

## Custom Image

- [strimzi-qe/strimzi-tests](https://quay.io/repository/strimzi-qe/strimzi-tests)
- To see Dockerfile, please contact someone from AMQ Streams QE.
