# Shared Azure Monitor Workspaces

## Rollout Hold

Keep the release PR in draft and `/hold` until all of these conditions are met.
Do not rehearse a deploying job or apply the Boskos inventory during this hold.

1. The personal environment currently using the sole services and HCP workspaces
   has detached all ingestion streams. Detach its associations and remote-write
   clients; **do not destroy the shared workspaces** or their managed resources.
2. The companion Azure/ARO-HCP shared-AMW PR has merged, including the catalog,
   lease resolver, external-workspace infrastructure support, and baseline catalog
   preservation. Its image publication must have completed.
3. The ARO-HCP source in every consuming job includes those changes. For upgrades,
   verify both `PULL_BASE_SHA` (or fetched main for rehearsals/periodics) and the
   **actually resolved ACR artifact revision**, including any historical fallback,
   include the companion changes. Rebase or rerun stale jobs. An older baseline
   does not understand external IDs; do not patch it with a compatibility shim or
   allow it to silently create dedicated workspaces.
4. Verify the catalog IDs and CI permissions against the shared resources, then
   explicitly remove the hold to activate the inventory and workflow leases.

## Contract

| Boskos Type | Resource Name | Workflow Environment | Count |
| --- | --- | --- | --- |
| `aro-hcp-services-amw-dev` | `services-ci-pool-0` | `SVC_AMW_LEASE` | 1 |
| `aro-hcp-hcps-amw-dev` | `hcps-ci-pool-0` | `HCP_AMW_LEASE` | 1 |

These are two independent global pools, not regional or subscription slots.
The ARO-HCP catalog `dev-infrastructure/openshift-ci/amw-pool.yaml` maps each name
under `amwPool` to `workspaceId`, `location`, and `purpose` (`services` or `hcps`).
`AMW_POOL_CATALOG` optionally selects another catalog. Cross-region and
cross-subscription ingestion is supported; catalog location does not select the
job's deployment region.

The provisioning resolver rejects missing/malformed catalogs, unknown or multiple
lease names, incomplete entries, wrong purposes, invalid workspace ARM IDs, and
services/HCP aliases to the same workspace. There is no cold-workspace fallback
for a supplied lease. `SVC_AMW_RESOURCE_ID` and `HCP_AMW_RESOURCE_ID` remain
independent direct-ID inputs, but a direct ID and a lease for the same purpose
are mutually exclusive, even when the ID matches. With neither input, config
defaults remain unchanged. Lease environment variables are injected by
ci-operator, not user-configurable empty defaults on individual refs.

## Workflow Coverage

| Consumer | Lease Window |
| --- | --- |
| `aro-hcp-local-e2e` (`e2e-parallel`) | Before runtime slot acquisition through provisioning, tests, gathering, and deprovisioning |
| `aro-hcp-local-e2e-upgrade` (`e2e-parallel-inplace-upgrade`) | The same pair and identity leases across baseline, PR upgrade, gathering, and cleanup |
| `aro-hcp-hypershift-e2e` | All public/private main and release-branch consumers, including periodics; includes image publication/polling, provisioning, tests, and cleanup |
| Inline CAPZ `dev` in `Azure-ARO-HCP-main__capz-e2e.yaml` | Before runtime slot acquisition through CAPZ tests and both CAPZ/ARO cleanup |

All four declare AMW leases at workflow/test scope beside the existing MSI mock
and ARM helper leases. HyperShift's identity declarations are moved from its
deploy ref to the workflow for consistency. ci-operator aggregates both ref and
workflow declarations into the test-wide lease lifecycle, renews them while the
job runs, and releases them after post steps. The existing runtime slot-manager
continues to manage only its existing resources; it does not allocate AMWs.

The named `aro-hcp-cspr` workflow is **not ephemeral**: it deploys the persistent
CSPR environment in a postsubmit, with no teardown. It must not borrow this pair
and release it while its clusters continue ingesting. No ephemeral CSPR workflow
exists in this release revision. CSPR, persistent INT/STG/PROD tests, CAPZ
`production`, shared monitoring, and `aro-hcp-provision-healthcheck` are unchanged.

## Queueing And Cleanup

With one workspace per purpose, jobs using both pools serialize globally.
ci-operator's default acquisition timeout is **two hours per resource type**,
not the job timeout or the lease lifetime. It acquires types in sorted order,
so a waiter may hold identity resources before obtaining both AMWs. A failure to
acquire releases the resources already obtained and fails before provisioning;
it must not switch to unleased workspaces.

Local E2E and upgrade jobs inherit the eight-hour Prow decoration timeout;
their test steps alone allow four and eight hours, respectively. The upgrade
step's full allowance cannot fit alongside provisioning in that job budget.
HyperShift public jobs inherit a
24-hour timeout, private jobs the eight-hour default, and CAPZ `dev` explicitly
allows four hours total. Builds and acquisition consume the job budget too.
Consequently, a queued job can exhaust the two-hour acquisition window while a
healthy holder is still running. This initial one-pair rollout deliberately keeps
that bounded fail-closed behavior, rather than introducing an allocator or
silently extending all jobs. Account for it when scheduling initial validation;
increase inventory or explicitly review acquisition/job budgets before scaling.

Lease release is not proof of Azure cleanup. If cancellation or a failed post
step leaves producers running, stop new shared-AMW jobs and detach or clean up
those producers before reusing the pair. Never delete the shared workspaces as
part of ephemeral environment cleanup.

## Local Validation

Run from the companion ARO-HCP checkout, with real `yq` and `jq`:

```bash
bash hack/ci/build-config-override_test.sh /path/to/release
```

This exercises the shared helper, provisioner, baseline path, and release's
duplicate provisioner with direct IDs, catalog leases, rejection cases, and
baseline/upgrade consistency. In release, run `bash hack/validate-boskos.sh` and
the ci-tools registry validator. No Azure deployment is needed for these checks.
