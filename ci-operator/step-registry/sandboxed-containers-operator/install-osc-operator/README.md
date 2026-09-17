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
- `peerpods-param-cm` ConfigMap in default namespace (created by `peerpods-param-cm` step, when peer-pods enabled)
- `peerpods-param-secret` Secret in default namespace (created by `peerpods-param-cm` step, when peer-pods enabled)

## AWS Peer-Pods: VM Import/Export Prerequisites

When `WORKLOAD_TO_TEST=peer-pods` (or `coco`) on AWS, the OSC operator builds a
podvm AMI using AWS's "manual credentials" VM Import/Export flow, which requires
an S3 bucket and a `vmimport` IAM role to already exist in the target AWS
account. This step waits (up to 5 minutes) for the operator-managed
`aws-podvm-image-cm` ConfigMap to appear, reads the expected bucket name from
it, and idempotently creates the bucket and `vmimport` role (with a policy
scoped to that bucket) using the same AWS credentials already available via
`peerpods-param-secret`. If the ConfigMap doesn't appear in time, this is
logged as a warning and the step continues (non-fatal).
