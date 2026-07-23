# amq-broker-install-and-tests-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisite--s-)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)
- [Custom Images](#custom-images)

## Purpose

To execute AMQ Broker interop tests. All XML results will be saved into "$ARTIFACT_DIR".

## Process

This script does the following to run AMQ Broker interop tests
1. Copy and Set KUBECONFIG to `/app/.kube/config`
2. Run `operator-suite/container/scripts/run-test.sh` with specified env variables.
3. Move xmls to `${ARTIFACT_DIR}/junit_*.xml`.

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.

### Environment Variables

- `TEST_IMAGE_TAG`
  - **Definition**: Image tag selected for image quay.io/rhmessagingqe/claire.
  - **If left empty**: This step will use default value i.e., "amq-broker-lpt".

## Custom Images

- `amq-broker-test-image`
  - CI registry image mirrored from [quay.io](quay.io/rhmessagingqe/claire:amq-broker-lpt).