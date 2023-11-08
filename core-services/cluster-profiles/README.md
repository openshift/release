# Cluster Profiles

This folder contains configuration related to cluster profiles.

The `_config.yaml` file contains a list of cluster profiles whose owners wish for them to be private; their usage restricted to specific organizations and repositories.

### Intended use
An owner in the owners list is an `org` with the option to specify `repos`.
When an `org` specifies one or more `repos`, the usage of the cluster profile is limited to those specified repositories.
If a cluster profile doesn't have the `owners` field defined, its usage remains unrestricted.

**Example 1: Restricting access to multiple repositories:**
```yaml
- profile: cluster-profile-name
  owners:
    - org: org
      repos:
        - repo1
        - repo2
```

**Example 2: Restricting access to more than one org:**
```yaml
- profile: cluster-profile-name
  owners:
    - org: org
      repos:
        - repo
    - org: org2
    - org: org3
```

### Future Plans
We plan to move cluster profiles here, allowing them to exist as a configuration file instead of as code in `ci-tools` as is described in our [documentation](https://docs.ci.openshift.org/docs/how-tos/adding-a-cluster-profile/).
