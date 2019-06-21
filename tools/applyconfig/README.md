# ApplyConfig

ApplyConfig is a tool for checking and applying cluster and service
configuration to the cluster. It behaves similarly to `oc apply -f directory/ --recursive`
but knows some additional DPTP conventions:

1. Knows the distinction between admin resources and other resources
2. Allows non-resources YAML files to be present
3. Ignores directories and files that are marked by a convention 
4. Ignores JSON files

## Usage

In general, `applyconfig --config-dir DIRECTORY` searches for all resource
config files under `DIRECTORY` and applies it. Subdirectories are searched
recursively and directories with names starting with `_` are skipped. Files and
directories are searched and applied in lexicographical order. All YAML files
are considered to be a config to apply, except those with filenames starting
with `_`. Files starting with `admin_` are considered to be admin resources, all
others are considered standard resources.

By default, `applyconfig` only runs in dry-mode, validating that eventual full
run would be successful. To issue a full run that actually commits the config
to the cluster, add a `--confirm=true` option.

By default, `applyconfig` works with non-admin resources. To apply admin
resources, use a `--level=admin` option. It is also possible to use
`--level=all` to apply both admin and standard resources. In this case, **all**
admin resources are applied first.

By default, standard resources are applied using user's standard credentials and
admin resources are attempted to apply as `system:admin`. It is possible to pass
the username to impersonate using the `--as=USER` option.
