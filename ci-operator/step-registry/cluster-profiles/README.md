# Cluster Profiles

This folder contains configuration related to cluster profiles.

The `cluster-profiles-config.yaml` file contains a list of cluster profiles whose owners wish for them to be private; their usage restricted to specific organizations and repositories.

## Intended use
Ownership of a cluster profile is defined in two ways, depending from which CI system the owner comes from.

### OpenShift CI
An owner in `OpenShift CI` is an `org` with the option to specify `repos`.
When an `org` specifies one or more `repos`, the usage of the cluster profile is limited to those specified repositories.
If a cluster profile doesn't have the `owners` field defined, its usage remains unrestricted.

**Example 1: Restricting access to multiple repositories:**
```yaml
cluster_profiles:
- name: cluster-profile-name
  owners:
    - org: org
      repos:
        - repo1
        - repo2
```

**Example 2: Restricting access to more than one org:**
```yaml
cluster_profiles:
- name: cluster-profile-name
  owners:
    - org: org
      repos:
        - repo
    - org: org2
    - org: org3
```

### Konflux CI
An owner in `Konflux CI` is a `tenant` along with the `cluster`'s name it is defined into.

**Example 1: Map a tenant to a single cluster**
```yaml
cluster_profiles:
- name: cluster-profile-name
  owners:
    - konflux:
        tenant: foobar
        clusters:
          - kflux-prd-rh02
```

**Example 2: Cluster groups**  
Since Konflux CI defines a separate sets of clusters per environment, it might be convenient referring to a `cluster_group` name rather than repeating the same names over and over.
```yaml
konflux:
  cluster_groups:
    prod:
      - stone-prd-rh01
      - kflux-prd-rh02
      - kflux-prd-rh03
    staging:
      - stone-stg-rh01
      - stone-stage-p01

cluster_profiles:
- name: cluster-profile-name-1
  owners:
    - konflux:
        tenant: foobar
        cluster_groups:
          - prod
```

Using both `clusters` and `cluster_groups` is allowed: the result is a list that contains the clusters defined in `clusters` and in each `clusters_groups`.
```yaml
- name: cluster-profile-name-2
  owners:
    - konflux:
        tenant: foobar
        clusters:
          - dev
        cluster_groups:
          - staging
```
The resulting cluster list from the example above is: `["dev", "stone-stg-rh01", "stone-stage-p01"]`.

Konflux's environments are defined in [https://konflux.pages.redhat.com/docs/users/cluster-info/cluster-info.html](https://konflux.pages.redhat.com/docs/users/cluster-info/cluster-info.html).


## Future Plans
We plan to move cluster profiles here, allowing them to exist as a configuration file instead of as code in `ci-tools` as is described in our [documentation](https://docs.ci.openshift.org/docs/how-tos/adding-a-cluster-profile/).
