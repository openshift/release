# mta-deploy-tackle-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To deploy Tackle in a specified namespace with specified `hub_bucket_volume_size`, `cache_data_volume_size`, and `rwx_supported` values. This step is necessary to execute the interop tests for the MTA operator.

## Process

This script uses `oc` to deploy Tackle, then checks every 30 seconds (60 retries) if the deployment is complete and ready. If it isn't ready within the specified number of retries, the script will fail.

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.
  - This cluster should have a namespace that matches `$TACKLE_NAMESPACE` or the default namespace of `mta`

### Environment Variables

- `TACKLE_NAMESPACE`
  - **Definition**: Namespace to deploy Tackle in.
  - **If left empty**: Will use the `mta` namespace.
- `HUB_BUCKET_VOLUME_SIZE`
  - **Definition**: Value for hub_bucket_volume_size.
  - **If left empty**: Will use `80Gi` as the value.
- `CACHE_DATA_VOLUME_SIZE`
  - **Definition**: Value for cache_data_volume_size.
  - **If left empty**: Will use `20Gi` as the value.
- `RWX_SUPPORTED`
  - **Definition**: Value for Value for rwx_supported.
  - **If left empty**: Will use `false` as the value.