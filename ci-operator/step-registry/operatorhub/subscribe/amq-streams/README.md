# operatorhub-subscribe-amq-streams-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To deploy the AMQ streams Operator in a specified namespace using a specified source and channel.

## Process

The test step's script automates the installation of the AMQ operator into a specified OpenShift namespace. It verifies the required environment variables, such as the namespace, package, and channel, and proceeds to subscribe to the operator responsible for managing the package. After a brief sleep, it retrieves the ClusterServiceVersion (CSV) associated with the package, retrying up to 30 times with 30-second intervals until the CSV is obtained or a timeout is reached. If the package is successfully deployed, it prints a success message; otherwise, it displays an error message with detailed information about the failed deployment. The script is designed to ensure the smooth installation of the AMQ operator, automating the necessary steps and handling potential errors.

## Prerequisite(s)
- `oc`
### Infrastructure

- A provisioned test cluster to target.

### Environment Variables

- `AMQ_PACKAGE`
  - **Definition**: The package name of the AMQ Operator to install.
  - **If left empty**: Will use `amq-streams` as package name.

- `AMQ_SOURCE`
  - **Definition**: The catalog source name.
  - **If left empty**: Will use `redhat-operators` as source.

- `AMQ_CHANNEL`
  - **Definition**: The channel from which to install the package.
  - **If left empty**: Will use `stable`as channel.

- `AMQ_NAMESPACE`
  - **Definition**: The namespace into which the operator will be installed. If left empty, a new namespace will be created.
  - **If left empty**: Will use `openshift-operators` as namespace.

- `AMQ_TARGET_NAMESPACES`
  - **Definition**: A comma-separated list of namespaces the operator will target. If left empty, all namespaces will be targeted. If no OperatorGroup exists in $AMQ_NAMESPACE, a new one will be created with its target namespaces set to $AMQ_TARGET_NAMESPACES. Otherwise, the existing OperatorGroup's target namespace set will be replaced. The special value "!install" will set the target namespace to the operator's installation namespace.
  - **If left empty**: "Will target all namespaces."

