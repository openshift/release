# Cluster Pools

This folder contains configuration related to cluster pools.

The `_config.yaml` file contains a list of cluster pools whose owners wish for them to be private; their usage restricted to specific organizations and repositories.

### Intended use
An owner in the owners list is an `org` with the option to specify `repos`.
When an `org` specifies one or more `repos`, the usage of the cluster pool is limited to those specified repositories.
If a cluster pool doesn't have the `owners` field defined, its usage remains unrestricted.

**Example 1: Restricting access to multiple repositories:**
```yaml
- claim: cluster-pool-name
  owners:
    - org: org
      repos:
        - repo1
        - repo2
```

**Example 2: Restricting access to more than one org:**
```yaml
- claim: cluster-pool-name
  owners:
    - org: org
      repos:
        - repo
    - org: org2
    - org: org3
```

