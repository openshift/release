# springboot-tests-interop-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)

## Purpose

To execute the Springboot interoperability tests against an ephemeral cluster and archive any results and test logs in the `$ARTIFACT_DIR`.

## Process

This script does the following to execute the Springboot interop tests:

1. Sets required varaibles.
2. Defines the `archive-results` function, used to move logs and JUnit results to the `$ARTIFACT_DIR` upon test completion.
3. Executes the [`/spring-boot-openshift-interop-tests/interop.sh`](https://github.com/rhoar-qe/spring-boot-openshift-interop-tests/blob/main/interop.sh) script using the required arguments.

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.
  - This cluster should have a `springboot` namespace.
