# Adding New Production Regions to ARO-HCP Testing

This guide shows how to add periodic CI tests for new ARO-HCP production regions.

## Steps

### 1. Add E2E Tests for New Regions

Edit `ci-operator/config/Azure/ARO-HCP/Azure-ARO-HCP-main__periodic.yaml` and add e2e-parallel tests for each new region.

Example:

```yaml
- as: prod-${region}-e2e-parallel
  cron: '@daily'
  steps:
    env:
      ARO_HCP_SUITE_NAME: prod/parallel
      SUBSCRIPTION: ARO HCP E2E
      TENANT_ID: 93b21e64-4824-439a-b893-46c9b2a51082
      LOCATION: ${region}
    pre:
    - ref: aro-hcp-provision-azure-login
    post:
    - ref: aro-hcp-provision-aro-hcp-gather-extra
    - chain: aro-hcp-provision-teardown-cluster
    test:
    - ref: aro-hcp-tests-run-aro-hcp-tests
```

Replace `${region}` with the Azure region name (e.g., `brazilsouth`, `centralindia`).

### 2. Generate Job Configurations

```bash
make ci-operator-config
make jobs
```

### 3. Open the PR

Follow the PR workflow as instructed per openshift-ci-bot to get the PR merged. You'll have to make use of the `pj-rehearse` plugin to test the added/modified jobs.

#### Example PRs

- [Original production setup](https://github.com/openshift/release/pull/68387) - Shows initial production environment setup
- [Adding new regions](https://github.com/openshift/release/pull/68612) - Shows the approach for additional regions

#### Validation Checklist

- [ ] Only e2e-parallel tests added (no cluster creation or cleanup jobs)
- [ ] `@daily` schedule used for new regions
- [ ] Correct naming conventions followed
- [ ] Generated job files look correct
- [ ] Rehearsal tests pass


### 4. Enable visualization for new jobs

To display the new jobs in the [ARO production dashboard](https://sippy.dptools.openshift.org/sippy-ng/release/aro-production), submit a PR to the Sippy repository following the pattern shown in [PR #2910](https://github.com/openshift/sippy/pull/2910).

Note: This step will become unnecessary once a standardized regex pattern is implemented.
