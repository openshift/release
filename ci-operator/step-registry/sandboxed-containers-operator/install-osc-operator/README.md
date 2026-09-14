# sandboxed-containers-operator-install-osc-operator

Installs the OpenShift Sandboxed Containers (OSC) operator and configures the
cluster for the target workload (kata, peer-pods, or coco).

## Overview

This step uses Helm charts from the [confidential-devhub/charts](https://github.com/confidential-devhub/charts)
repository to install the OSC operator and configure operands. It follows a
two-phase install: first the operator (namespace, subscription, CSV), then the
operands (KataConfig, feature gates, peer-pods configuration).

The step is a no-op by default (`OSC_INSTALL=false`) so it can live in the
shared `sandboxed-containers-operator-pre` chain without affecting jobs that
do not need it.

## Workload Types

| Workload | ENABLEPEERPODS | WORKLOAD_TO_TEST | What gets configured |
|----------|---------------|-----------------|---------------------|
| kata | false | kata | KataConfig (bare metal kata runtime) |
| peer-pods | true | peer-pods | KataConfig + peer-pods-cm + peer-pods-secret |
| coco | true | coco | KataConfig + peer-pods-cm + peer-pods-secret + confidential feature gate |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OSC_INSTALL` | `false` | Set to `true` to enable installation |
| `OSC_CHARTS_REPO` | `https://github.com/confidential-devhub/charts.git` | Git repo URL for Helm charts |
| `OSC_CHARTS_REF` | `main` | Git ref (branch/tag/commit) |
| `CATALOG_SOURCE_IMAGE` | `""` | Custom CatalogSource image for dev/pre-GA |
| `ENABLEPEERPODS` | `false` | Enable peer-pods in KataConfig |
| `WORKLOAD_TO_TEST` | `kata` | Workload type: kata, peer-pods, or coco |
| `OSC_NAMESPACE` | `openshift-sandboxed-containers-operator` | Target namespace |

## Prerequisites

This step expects the following to be available (created by earlier steps in the chain):

- `osc-config` ConfigMap in default namespace (created by `env-cm` step)

For peer-pods enabled workloads, the step auto-detects cloud provider configuration from cluster infrastructure. You can override detected values by setting environment variables:

**Common variables:**
- `VXLAN_PORT` - VXLAN port (default: 9000)
- `PROXY_TIMEOUT` - Proxy timeout (default: 30m)

**Azure provider:**
- `AZURE_SUBNET_ID` - Azure subnet ID
- `AZURE_NSG_ID` - Azure NSG ID
- `AZURE_RESOURCE_GROUP` - Azure resource group
- `AZURE_REGION` - Azure region
- `AZURE_INSTANCE_SIZE` - VM instance size (default: Standard_D2s_v3)
- `AZURE_SSH_KEY_PUB` - SSH public key

**AWS provider:**
- `AWS_REGION` - AWS region
- `AWS_SUBNET_ID` - AWS subnet ID
- `AWS_VPC_ID` - AWS VPC ID
- `AWS_SG_IDS` - AWS security group IDs
- `PODVM_INSTANCE_TYPE` - EC2 instance type (default: t3.medium)

**GCP provider:**
- `GCP_PROJECT_ID` - GCP project ID
- `GCP_ZONE` - GCP zone
- `GCP_NETWORK` - GCP network
- `GCP_MACHINE_TYPE` - GCP machine type (default: e2-standard-4)
