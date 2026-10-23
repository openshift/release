# ROSA E2E metadata indexing

The Classic and HCP ROSA E2E workflows use `rosa-cluster-deprovision-no-index`.
It retains the `gather` chain and `rosa-cluster-deprovision` ref, but does not include
`rosa-cluster-index` or its `ocp-perfscale` / `production-es` credential.
All other workflow diagnostics and cleanup steps remain in place.

Credential discovery occurs before step commands execute. Setting
`INDEX_ENABLED: "false"` on a job that still includes `rosa-cluster-index`
does not prevent discovery of that step's credentials. The no-index chain
omits the step at configuration resolution time instead.

## Selecting indexing explicitly

The existing `rosa-cluster-deprovision` chain remains the indexing-capable
path: `gather`, `rosa-cluster-deprovision`, then `rosa-cluster-index`.
Workflows such as `rosa-aws-sts-hcp` and `rosa-aws-sts-hcp-mp` still select
that chain. Jobs using those workflows enable uploads with
`INDEX_ENABLED: "true"`; their indexing step and credentials are unchanged.

To enable indexing in a ROSA E2E job, explicitly supply the workflow's
complete `steps.post` list in the job configuration, replacing only
`chain: rosa-cluster-deprovision-no-index` with
`chain: rosa-cluster-deprovision`, and set `steps.env.INDEX_ENABLED: "true"`.
Keep every other post entry, its order and `best_effort` setting from the
selected workflow, including diagnostics, role/OIDC cleanup, VPC cleanup,
stack deletion and HCP diagnostics where present. An explicit `post` list
replaces the workflow's entire post list; it does not append to it.
Setting the environment variable alone cannot add a step to the resolved
configuration and is rejected as an undeclared parameter when no step uses it.
