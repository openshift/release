# distributed-tracing-install-opentelemetry-product-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To deploy the OpenTelemetry Operator in a specified namespace using a specified source and channel.

## Process

This step uses a bash script which is designed to install OpenTelemetry Operator into a specified namespace. The script first verifies if the required variables (OTEL_NAMESPACE, OTEL_PACKAGE, OTEL_CHANNEL) are defined, displaying an error and exiting if any are missing. It then proceeds to subscribe to the operator using the provided information. After a 60-second sleep delay, the script checks the deployment status in a loop with a maximum of 30 retries, waiting for the deployment to succeed. The estimated time for this step is a maximum of 15 minutes. If the deployment fails, an error message with deployment details is displayed, and the script exits with an error status. Finally, if the installation is successful, a success message is printed. It's important to note that the actual time for each step may vary depending on system performance and network conditions.

## Prerequisite(s)
- `oc`
  
### Infrastructure

- A provisioned test cluster to target.

### Environment Variables

- `OTEL_PACKAGE`
  - **Definition**: The package name of the OpenTelemetry Operator to install.
  - **If left empty**: Will use the "opentelemetry-product" package name.

- `OTEL_SOURCE`
  - **Definition**: The catalog source name from which OpenTelemetry Operator to be installed.
  - **If left empty**: Will use the "redhat-operators" source.

- `OTEL_CHANNEL`
  - **Definition**: The channel from which to install the operator.
  - **If left empty**: Will use the "stable" channel.

- `OTEL_NAMESPACE`
  - **Definition**: The namespace into which the operator will be installed.
  - **If left empty**: Will use the "openshift-operators" namespace.

- `OTEL_TARGET_NAMESPACES`
  - **Definition**: A comma-separated list of namespaces the operator will target. If empty, all namespaces will be targeted. If no OperatorGroup exists in $OTEL_NAMESPACE, a new one will be created with its target namespaces set to $OTEL_TARGET_NAMESPACES, otherwise the existing OperatorGroup's target namespace set will be replaced. The special value "!install" will set the target namespace to the operator's installation namespace.
  - **If left empty**: "All namespaces will be targeted."