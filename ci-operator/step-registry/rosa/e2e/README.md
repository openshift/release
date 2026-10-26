# ROSA E2E metadata indexing

The common `rosa-cluster-deprovision` chain gathers diagnostics and deprovisions
the cluster. It does not include `rosa-cluster-index` or its `ocp-perfscale` /
`production-es` credential. Classic and HCP ROSA E2E workflows use this common
teardown, retaining their other diagnostic and cleanup steps.

Credential discovery occurs before step commands execute. Setting
`INDEX_ENABLED: "false"` on a job that still includes `rosa-cluster-index`
does not prevent discovery of that step's credentials. Omitting the indexing
ref from the job's composed steps avoids that dependency at resolution time.

## Selecting indexing explicitly

Jobs that enable uploads explicitly include the reusable `rosa-cluster-index`
ref immediately after the common teardown and set `steps.env.INDEX_ENABLED`
to `"true"`. The indexing ref still owns its credentials and upload commands.

An explicit `steps.post` list replaces the workflow's entire post list; it does
not append to it. Preserve every other entry, its order and its `best_effort`
setting, including diagnostics, role/OIDC cleanup, VPC cleanup and stack deletion.

For example, `rosa-aws-sts-hcp` and `rosa-aws-sts-hcp-mp` normally select the
`rosa-aws-sts-hcp-deprovision` wrapper followed by result reporting. To retain
indexing before OIDC and stack cleanup, an enabled job composes:

```yaml
steps:
  env:
    INDEX_ENABLED: "true"
  post:
  - chain: rosa-cluster-deprovision
  - ref: rosa-cluster-index
  - chain: rosa-sts-oidc-config-delete
  - ref: aws-deprovision-stacks
  - ref: send-results-to-reportportal
  workflow: rosa-aws-sts-hcp
```

This is not a universal post list: Classic STS jobs retain account-role cleanup
instead, and E2E workflows have their own additional diagnostics and cleanup.
Expand only the necessary wrapper to place the index ref at its original point;
do not append it after the wrapper's remaining cleanup. The existing enabled
performance and chaos jobs explicitly preserve their previous resolved sequence.

Setting the environment variable alone cannot add a step. Without a step that
declares it, `INDEX_ENABLED` is rejected as an undeclared parameter. Disabled
jobs should omit both the indexing ref and any now-unused indexing-only settings.
