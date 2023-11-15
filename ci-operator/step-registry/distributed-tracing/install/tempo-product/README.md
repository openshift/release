# distributed-tracing-install-tempo-product-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To deploy the Tempo Operator in a specified namespace using a specified source and channel.

## Process

This step uses a bash script which installs the Tempo Operator into a specified namespace. It verifies the presence of required variables and displays an error if any are missing. After subscribing to the operator, it waits for the deployment to succeed, allowing for a maximum of 30 retries with a 30-second interval. If the deployment fails, it provides detailed information about the failure. The overall time for the steps depends on various factors but can be estimated to take at least a few minutes due to the sleep periods and potential retries.

## Prerequisite(s)
- `oc`
  
### Infrastructure

- A provisioned test cluster to target.

### Environment Variables

- `TEMPO_PACKAGE`
  - **Definition**: The package name of the Tempo Operator to install.
  - **If left empty**: Will use the "tempo-product" package.

- `TEMPO_SOURCE`
  - **Definition**: The catalog source name from which Tempo will be installed.
  - **If left empty**: Will use the "redhat-operators" source.

- `TEMPO_CHANNEL`
  - **Definition**: The channel from which to install the package.
  - **If left empty**: Will use the 'stable' channel.

- `TEMPO_NAMESPACE`
  - **Definition**: The namespace into which the operator will be installed.
  - **If left empty**: Will use the "openshift-operators" namespace.

- `TEMPO_TARGET_NAMESPACES`
  - **Definition**: A comma-separated list of namespaces the operator will target. If empty, all namespaces will be targeted. If no OperatorGroup exists in $TEMPO_NAMESPACE, a new one will be created with its target namespaces set to $TEMPO_TARGET_NAMESPACES, otherwise the existing OperatorGroup's target namespace set will be replaced. The special value "!install" will set the target namespace to the operator's installation namespace.
  - **If left empty**: Will target all the namespaces.

