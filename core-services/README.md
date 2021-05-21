# Core Services and Configuration

_Only `core-services/secrets` folder is applied to the cluster api.ci._

Except [user secret management](https://docs.ci.openshift.org/docs/how-tos/adding-a-new-secret-to-ci/), no services are running on `api.ci`.

## Quality criteria and conventions

1. All directories should contain `OWNERS` and `README.md` files. This is
enforced by `make check` locally and by the `ci/prow/core-valid` check on
pull requests.
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
4. The `config-updater` service account in the `ci` namespace must have
permissions to apply all standard resources.
5. Destination namespaces should always be specified within a manifest, never
rely on a currently set OpenShift project.
6. All ConfigMaps need to be set up for automated updates by the
`config-updater` Prow plugin.

## How to apply

There are two types of configuration: resources and ConfigMaps.

### Automation

1. Everything is automatically applied to the cluster by a prow
   [postsubmit](https://prow.ci.openshift.org/?job=branch-ci-openshift-release-master-core-apply)
   after each PR is merged, and also [periodically](https://prow.ci.openshift.org/?job=openshift-release-master-core-apply).
1. ConfigMaps are automatically updated by the `config-updater` Prow plugin,
   configured in its [config.yaml](02_config/_config.yaml) file.
   Additionally, they are [periodically](https://prow.ci.openshift.org/?job=openshift-release-master-config-bootstrapper)
   synced by a Prow job.


### Manual

1. Resources can be created by `make core`, provided the user has rights
   to perform all necessary actions
1. ConfigMaps can be manually created by the [config-bootstrapper](https://github.com/kubernetes/test-infra/tree/master/prow/cmd/config-bootstrapper)
   tool.

Additionally, the [`applyconfig`](https://github.com/openshift/ci-tools/tree/master/cmd/applyconfig) can be used directly.
See its [README.md](https://github.com/openshift/ci-tools/blob/master/cmd/applyconfig/README.md) for more details.
