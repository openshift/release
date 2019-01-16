# Populating `OWNERS` and `OWNERS_ALIASES`

This utility updates the OWNERS files from remote Openshift repositories.

Usage:
  populate-owners [repo-name-regex]

Args:
  [repo-name-regex]    A go regex which which matches the repos to update, by default all repos are selected

```console
$ go run main.go [repo-name-regex]
```

Or, equivalently, execute [`populate-owners.sh`](../../ci-operator/populate-owners.sh) from anywhere in this repository.

Upstream repositories are calculated from `ci-operator/jobs/{organization}/{repository}`.
For example, the presence of [`ci-operator/jobs/openshift/origin`](../../ci-operator/jobs/openshift/origin) inserts [openshift/origin][] as an upstream repository.

The `HEAD` branch for each upstream repository is pulled to extract its `OWNERS` and `OWNERS_ALIASES`.
If `OWNERS` is missing, the utility will ignore `OWNERS_ALIASES`, even if it is present upstream.

Any aliases present in the upstream `OWNERS` file will be resolved to the set of usernames they represent in the associated
`OWNERS_ALIASES` file.  The local `OWNERS` files will therefore not contain any alias names.  This avoids any conflicts between 
upstream alias names coming from  different repos.

The utility also iterates through the `ci-operator/{type}/{organization}/{repository}` for `{type}` in `config`, `jobs`, and `templates`, writing `OWNERS` to reflect the upstream configuration.
If the upstream did not have an `OWNERS` file, the utility removes the associated `ci-operator/*/{organization}/{repository}/OWNERS`.

[openshift/origin]: https://github.com/openshift/origin
[openshift/installer]: https://github.com/openshift/installer
