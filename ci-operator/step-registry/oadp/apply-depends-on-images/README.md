# oadp-apply-depends-on-images-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
  - [Environment Variables](#environment-variables)
- [OLM version seam](#olm-version-seam)
- [Provenance](#provenance)

## Purpose

Applies whatever [`oadp-depends-on-build`](../depends-on-build/README.md) resolved (`${SHARED_DIR}/depends-on-images.txt`) to the operator already installed in this test cluster. `oadp-depends-on-build` only builds images and writes a plain manifest -- it never touches an installed operator. This step is the other half: make a resolved image actually take effect.

A total no-op when that manifest doesn't exist or is empty -- the common case for any PR that doesn't use `Depends-On:` at all.

## Process

1. If `${SHARED_DIR}/depends-on-images.txt` is missing or empty: exit 0 immediately, no cluster interaction at all.
2. Otherwise, discover the single `Subscription` in `OO_INSTALL_NAMESPACE` (fails if zero or more than one is found).
3. Patch `Subscription.spec.config.env` with one entry per line in the manifest (a single merge patch, replacing the whole array).
4. Wait for `OO_MANAGER_DEPLOYMENT` to observe every one of those env vars, then wait for its rollout to finish.

### Environment Variables

- `OO_INSTALL_NAMESPACE` -- the namespace the operator under test is installed into.
- `OLM_API_VERSION` -- `v0` (default, implemented) or `v1` (reserved, not yet implemented -- see below).
- `OO_MANAGER_DEPLOYMENT` -- name of the manager Deployment to wait on (default: `openshift-adp-controller-manager`).

## OLM version seam

This ecosystem installs operators via OLMv0 (a `Subscription` whose `spec.config.env` is the supported per-install override mechanism) everywhere as of this writing. `operator-controller`'s `ClusterExtension` (OLMv1) is expected to eventually replace that, with a different config-override shape.

This step is deliberately the *only* place that knows how to make a resolved Depends-On image take effect -- `oadp-depends-on-build` is fully OLM-version-agnostic. `OLM_API_VERSION=v1` is reserved for that future work but **fails loudly** today (rather than silently no-opping), so a consumer that migrates to OLMv1 cannot accidentally believe Depends-On support carried over for free. Implementing it is future work tracked alongside [openshift/oadp-operator#2389](https://github.com/openshift/oadp-operator/issues/2389).

## Provenance

Written alongside [`oadp-depends-on-build`](../depends-on-build/README.md) for [openshift/oadp-operator#2389](https://github.com/openshift/oadp-operator/issues/2389). Patch/wait logic mirrors the `set-related-image` test step already inline in the 4 `migtools/kubevirt-datamover-{controller,plugin}` KDM e2e configs (openshift/oadp-operator#1832 / openshift/release#83049), generalized here as a standalone reusable step for consumers (like `openshift/oadp-operator`'s own e2e) that don't also need to apply an own-repo dependency image inline.
