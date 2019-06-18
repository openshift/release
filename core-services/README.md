# Core Services and Configuration

Manifests for important services (like [OpenShift CI cluster](https://api.ci.openshift.org/)
and the CI service components that run on it) are present in this directory. The
services configured here are critical for some part of the OpenShift project
development workflow, must meet basic quality criteria and must be deployed to
the cluster automatically by a postsubmit job.

## How to add new service

Create a new directory for your service, containing all [necessary files](#quality-criteria-and-conventions).
You may copy the `_TEMPLATE` directory and start using the files there. Add
manifests and other configuration as needed, and make sure the `Makefile` in
your directory applies all config when its `resources` and `admin-resources` are
built.

Add the name of the directory to the `SERVICES` list in the [Makefile](./Makefile).
You should not need to modify this or any other Makefile in any way.

## Quality criteria and conventions

1. All directories should contain `OWNERS`, `README.md` and `Makefile` files.
   This is enforced by `make check` locally and by the `ci/prow/core-valid`
   check on pull requests.
2. The `Makefile` should provide `resources` and `admin-resources` targets.
   Calling the former should create all resources for which admin permissions
   are not necessary. The `config-updater` service account in the `ci` namespace
   must have permissions to perform all actions done in the `resources` targets.
   Calling `admin-resources` should create all resources for which admin
   permissions is necessary. Presence of these targets is enforced by
   `make check` locally and by the `ci/prow/core-valid` check on pull requests.
   Additionally, `make dry-core{-admin}` runs the appropriate target in dry-run
   mode. Passing `make dry-core` is enforced by the `ci/prow/core-dry` check.
3. Makefiles and scripts called by them should use `$(APPLY)` variable instead
   of `oc apply`. This allows the universal dry-run to work.
4. Destination namespaces should always be specified within a manifest, never
   by a `-n/--namespace` option or by relying on a currently set OpenShift
   project.
5. All ConfigMaps need to be set up for automated updates by the
   `config-updater` Prow plugin.

## How to apply

There are three types of configuration: admin resources, other resources and
ConfigMaps.

### Automation

1. Admin resources are not automatically applied to the cluster.
2. Other resources are automatically applied to the cluster by a Prow
   [postsubmit](https://prow.svc.ci.openshift.org/?job=branch-ci-openshift-release-master-core-apply)
   after each PR is merged, and also [periodically](https://prow.svc.ci.openshift.org/?job=openshift-release-master-core-apply).
3. ConfigMaps are automatically updated by the `config-updater` Prow plugin,
   configured in its [config.yaml](../cluster/ci/config/prow/config.yaml) file.
   Additionally, they are [periodically](https://prow.svc.ci.openshift.org/?job=openshift-release-master-config-bootstrapper)
   synced by a Prow job.

### Manual

1. Admin resources can be created by users with `--as=system:admin` rights by
   `make core-admin`.
2. Other resources can be created by `make core`, provided the user has rights
   to perform all necessary actions
3. ConfigMaps can be manually created by the [config-bootstrapper](https://github.com/kubernetes/test-infra/tree/master/prow/cmd/config-bootstrapper)
   tool.
