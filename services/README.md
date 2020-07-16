# Additional Services and Configuration

This directory contains manifests and configuration for additional services
that:
 1. are running on [OpenShift CI cluster](https://api.ci.openshift.org/)
 2. are not critical for the development process of the whole OpenShift
    organization (critical service configuration is in [core-services](../core-services)).
 3. want to follow the same quality criteria and automated check and deployment
    process that the core services do (DPTP intends to support only these
    additional services).

## How to add new service

Create a new directory for your service, containing all [necessary files](#quality-criteria-and-conventions).
You may copy the [_TEMPLATE](../core-services/_TEMPLATE) directory and start
using the files there. Add manifests and other configuration as needed.

## Quality criteria and conventions

1. All directories should contain `OWNERS` and `README.md` files. This is
enforced by `make check-services` locally and by the `ci/prow/services-valid`
check on pull requests.
2. Config is applied to the cluster using the [`applyconfig`](https://github.com/openshift/ci-tools/tree/master/cmd/applyconfig)
tool. The tool applies all YAML files under your service subdirectory. Subdirectories are searched recursively and directories with names starting with _ are skipped. All
   YAML filenames should follow the following convention:
    - All admin resources should be in `admin_*.yaml` files
    - Names of YAML files that should not be applied to the cluster should start
      with `_`.
    - The remaining YAML files are considered "standard" resources.
3. `applyconfig` applies files in lexicographical order. In the case when some
resources need to be created before others, this needs to be reflected by the
naming of the files (e.g. by including a numerical component).
4. The `config-updater` service account in the `ci` namespace [must have
permissions](../core-services/prow/03_deployment/admin_config_updater_rbac.yaml)
to apply all standard resources.
5. Destination namespaces should always be specified within a manifest, never
rely on a currently set OpenShift project.
6. All ConfigMaps need to be [set up for automated updates](../core-services/prow/02_config/_plugins.yaml) by the `config-updater` Prow plugin.

## How to apply

There are three types of configuration: admin resources, other resources and
ConfigMaps.

### Automation

1. Admin resources are not automatically applied to the cluster.
2. Other resources are automatically applied to the cluster by a Prow
   [postsubmit](https://prow.ci.openshift.org/?job=branch-ci-openshift-release-master-services-apply)
   after each PR is merged, and also [periodically](https://prow.ci.openshift.org/?job=openshift-release-master-services-apply).
3. ConfigMaps are automatically updated by the `config-updater` Prow plugin,
   configured in its [config.yaml](02_config/_config.yaml) file.
   Additionally, they are [periodically](https://prow.ci.openshift.org/?job=openshift-release-master-config-bootstrapper)
   synced by a Prow job.

### Manual

1. Admin resources can be created by users with `--as=system:admin` rights by
   `make services-admin`.
2. Other resources can be created by `make services`, provided the user has rights
   to perform all necessary actions
3. ConfigMaps can be manually created by the [config-bootstrapper](https://github.com/kubernetes/test-infra/tree/master/prow/cmd/config-bootstrapper)
   tool.

Additionally, the [`applyconfig`](https://github.com/openshift/ci-tools/tree/master/cmd/applyconfig) can be used directly.
See its [README.md](https://github.com/openshift/ci-tools/blob/master/cmd/applyconfig/README.md) for more details.
