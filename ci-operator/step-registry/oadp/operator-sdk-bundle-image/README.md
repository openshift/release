# oadp-operator-sdk-bundle-image-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
  - [Environment Variables](#environment-variables)
- [Provenance](#provenance)

## Purpose

Install an optional operator from a provided non ci-bundle image via `operator-sdk run bundle`, with two opt-in behaviors needed by the KDM (kubevirt-datamover-controller/-plugin) e2e jobs: mirroring the bundle into the test cluster's own internal registry, and forcing PSA `privileged` enforcement on the install namespace.

## Process

Creates (or reuses) `OO_INSTALL_NAMESPACE`, applies the PSA labeling appropriate for it, optionally mirrors `OO_BUNDLE` into the cluster's internal registry (see `OO_MIRROR_TO_CLUSTER_REGISTRY` below), then runs `operator-sdk run bundle` against the effective bundle pullspec. On failure, dumps CatalogSource/Subscription/InstallPlan/pod/registry-pod-log diagnostics before exiting.

### Environment Variables

- `USE_HOSTED_KUBECONFIG`
  - When true, install the operator on the hosted cluster (default: `false`).
- `OO_INSTALL_NAMESPACE`
  - The namespace into which the operator and catalog will be installed.
- `OO_INSTALL_MODE`
  - The install-mode flag value of the `operator-sdk run bundle` command (default: `AllNamespaces`).
- `OO_INSTALL_TIMEOUT_MINUTES`
  - How long (in minutes) to wait for the installation, before giving up (default: `10`).
- `OO_SECURITY_CONTEXT`
  - Security context for the catalog pod created by operator-sdk: `restricted` or `legacy` (default: `restricted`).
- `OO_PSA_ENFORCE_PRIVILEGED`
  - When true, force `pod-security.kubernetes.io/enforce=privileged` on `OO_INSTALL_NAMESPACE` regardless of its name (default: `false`).
- `OO_MIRROR_TO_CLUSTER_REGISTRY`
  - When true, mirror `OO_BUNDLE` into the test cluster's own internal registry first and install from that copy instead. Works around operator-sdk's containerd-based bundle pull being unable to use credentials that work fine via `oc image mirror`/`oc image info` against some external registries. Mutates cluster-wide config (registry route, insecureRegistries, triggers an MCO rollout) and assumes an ephemeral, single-use test cluster (default: `false`).
- `OO_BUNDLE`
  - Specifies a non ci-bundle image.
- `DEPLOYMENT`
  - Deployment to be installed by the bundle. Optional; if empty, the check is skipped.

## Provenance

Forked from `optional-operators-operator-sdk-non-ci-bundle-image` (openshift/release#83049) into an OADP-owned copy so KDM-specific changes here don't require approval from that ref's OWNERS. Check that ref's git history periodically for upstream fixes worth porting into this fork manually.
