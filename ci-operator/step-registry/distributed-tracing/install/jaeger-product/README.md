# distributed-tracing-install-jaeger-product-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To deploy the Jaeger Operator in a specified namespace using a specified source and channel.

## Process

This step uses a bash script that checks if the specified variables for the Jaeger Operator (JAEGER_NAMESPACE, JAEGER_PACKAGE, JAEGER_CHANNEL) are defined, which is an instantaneous process. Then, the script creates the install namespace, typically completing quickly. Subsequently, a new operator group is deployed, which is expected to finish swiftly as well. The script proceeds by subscribing to the operator and waiting for the deployment to succeed. In the event of failure, the script retries the deployment up to 30 times, with a 30-second delay between each attempt, resulting in a maximum estimated time of 15 minutes. If the operator deployment fails, an error message with deployment details is displayed. Finally, if the installation is successful, a success message is outputted. It's important to note that actual time may vary due to system performance and network conditions.

## Prerequisite(s)
- `oc`
  
### Infrastructure

- A provisioned test cluster to target.

### Environment Variables

- `JAEGER_PACKAGE`
  - **Definition**: The package name of the Jaeger Operator to install.
  - **If left empty**: Will use the "jaeger-product" package.

- `JAEGER_SOURCE`
  - **Definition**: The catalog source name from which Jaeger will be installed.
  - **If left empty**: Will use the "redhat-operators" source.

- `JAEGER_CHANNEL`
  - **Definition**: The channel from which to install the package.
  - **If left empty**: Will use the 'stable' channel.

- `JAEGER_NAMESPACE`
  - **Definition**: The namespace into which the operator is installed. If a namespace doesn't exist, a new namespace will be created.
  - **If left empty**: Will use the "openshift-distributed-tracing" namespace.

- `JAEGER_TARGET_NAMESPACES`
  - **Definition**: A comma-separated list of namespaces the operator will target. If empty, all namespaces will be targeted. If no OperatorGroup exists in $JAEGER_NAMESPACE, a new one will be created with its target namespaces set to $JAEGER_TARGET_NAMESPACES, otherwise, the existing OperatorGroup's target namespace set will be replaced. The special value "!install" will set the target namespace to the operator's installation namespace.
  - **If left empty**: No target namespaces specified.

