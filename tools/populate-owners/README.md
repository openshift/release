# Populating `OWNERS` and `OWNERS_ALIASES`

This utility pulls `OWNERS` and `OWNERS_ALIASES` from upstream OpenShift repositories.
Usage:

```console
$ go run main.go
```

Or, equivalently, execute [`populate-owners.sh`](../../ci-operator/populate-owners.sh) from anywhere in this repository.

Upstream repositories are calculated from `ci-operator/jobs/{organization}/{repository}`.
For example, the presence of [`ci-operator/jobs/openshift/origin`](../../ci-operator/jobs/openshift/origin) inserts [openshift/origin][] as an upstream repository.

The `HEAD` branch for each upstream repository is pulled to extract its `OWNERS` and `OWNERS_ALIASES`.
If `OWNERS` is missing, the utility will ignore `OWNERS_ALIASES`, even if it is present upstream.

Once all the upstream content has been fetched, the utility namespaces any colliding upstream aliases.
Collisions only occur if multiple upstreams define the same alias with different member sets.
When that happens, the utility replaces the upstream alias with a `{organization}-{repository}-{upstream-alias}`.
For example, if [openshift/origin][] and [openshift/installer][] both defined an alias for `security` with different member sets, the utility would rename them to `openshift-origin-security` and `openshift-installer-security` respectively.

After namespacing aliases, the utility writes `OWNERS_ALIASES` to the root of this repository.
If no upstreams define aliases, then the utility removes `OWNER_ALIASES` from the root of this repository.

The utility also iterates through the `ci-operator/jobs/{organization}/{repository}` and `ci-operator/config/{organization}/{repository}` directories, writing `OWNERS` to reflect the upstream configuration.
If the upstream did not have an `OWNERS` file, the utility removes the associated `ci-operator/*/{organization}/{repository}/OWNERS`.

[openshift/origin]: https://github.com/openshift/origin
[openshift/installer]: https://github.com/openshift/installer
