# operatorhub-subscribe-elasticsearch-operator-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To deploy the Elasticsearch Operator in a specified namespace using a specified source and channel.

## Process

The step's script facilitates the installation of the Elasticsearch Operator on an OpenShift Container Platform. It begins by checking for a proxy configuration file and sourcing it if present. The script then verifies the required environment variables to ensure they are defined. Next, it creates an installation namespace and deploys a new operator group within that namespace. The operator is subscribed to by creating a subscription object, specifying the Elasticsearch Operator package, channel, and source details. Following a short sleep period to allow the resources to become available, the script enters a loop where it checks the deployment status for a specified number of retries. If the Elasticsearch Operator is successfully deployed, a success message is displayed. In the event of a failed deployment, an error message is printed, along with diagnostic information such as listing the catalog source, pods in the marketplace namespace, and providing detailed YAML and description of the failed deployment. The total execution time of the script varies depending on the number of retries and the duration of the sleep intervals between each retry.

## Prerequisite(s)
- `oc`
### Infrastructure

- A provisioned test cluster to target.

### Environment Variables

- `EO_SUB_PACKAGE`
  - **Definition**: The package name of the Elasticsearch operator to install.
  - **If left empty**: Will use the "elasticsearch-operator" package.

- `EO_SUB_SOURCE`
  - **Definition**: The catalog source name.
  - **If left empty**: Will use the "qe-app-registry" source.

- `EO_SUB_CHANNEL`
  - **Definition**: The channel from which to install the package.
  - **If left empty**: Will use the "stable" channel.

- `EO_SUB_INSTALL_NAMESPACE`
  - **Definition**: The namespace into which the operator and catalog will be installed. If empty, a new namespace will be created.
  - **If left empty**: Will use the "openshift-operators-redhat" namespace.

- `EO_SUB_TARGET_NAMESPACES`
  - **Definition**: A comma-separated list of namespaces the operator will target. If empty, all namespaces will be targeted. If no OperatorGroup exists in $EO_SUB_INSTALL_NAMESPACE, a new one will be created with its target namespaces set to $EO_SUB_TARGET_NAMESPACES. Otherwise, the existing OperatorGroup's target namespace set will be replaced. The special value "!install" will set the target namespace to the operator's installation namespace.
  - **If left empty**: "Will target all namespaces."
