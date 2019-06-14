# OpenShift Release Tooling

This repository holds OpenShift cluster manifests, component build manifests and
CI workflow configuration for OpenShift component repositories for both OKD and
OCP.

## CI Workflow Configuration

Configuration files for CI workflows live under [`ci-operator/`](./ci-operator/)
and are split into the following categories:

 - [`ci-operator/config`](./ci-operator/config/) contains configuration for the
   `ci-operator`, detailing builds and tests for component repositories. See the
   [contributing guide](./ci-operator/README.md) for details on how to configure
   new repositories or tests.
 - [`ci-operator/jobs`](./ci-operator/jobs/) contains configuration for `prow`,
   detailing job triggers. In almost all cases, this configuration can be
   generated automatically from the `ci-operator` config. For manual edits, see
   the [upstream configuration document](https://github.com/kubernetes/test-infra/blob/master/prow/README.md#how-to-add-new-jobs)
   for details on how to configure a job, but prefer the `ci-operator` config
   whenever possible.
 - [`ci-operator/templates`](./ci-operator/templates/) contains black-box test
   workflows for use by the `ci-operator`. The parent directory's
   [README](./ci-operator#end-to-end-tests) documents how to use them. See the
   [template document](https://github.com/openshift/ci-tools/blob/master/TEMPLATES.md)
   for general information on template tests.
 - [`ci-operator/infra`](./ci-operator/infra/) contains manifests for infrastructure
   components used by the `ci-operator`. Contact a CI Administrator if you feel
   like one of these should be edited.

## Cluster Configuration Manifests

Manifests for cluster provisioning and installation live under [`cluster/`](./cluster/).
The [OpenShift CI cluster](https://api.ci.openshift.org/) is configured with the
manifests under [`cluster/ci/`](./cluster/ci/); clusters that are created by the
testing infrastructure for validating OpenShift are configured with the profiles
under [`cluster/test-deploy/`](./cluster/test-deploy/). For directions on how to
set up clusters for development, see the [README](./cluster/test-deploy/README.md).

## Component Project Build Manifests

Manifests for building container images for component repositories live under
[`projects/`](./projects/). This directory is deprecated; authors of components
built by manifests in this directory should remove them and ensure that their
component is appropriately built by the `ci-operator` instead.

## Tooling Build Manifests

Manifests for building container images for tools live under [`tools/`](./tools/).
These tools are either useful in managing this repository or are otherwise useful
commonly across component repositories.
