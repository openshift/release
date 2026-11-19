# Deploy Policy in ACM hub to install CNV

## What this step does

1. Creates a Policy object in ACM that installs OpenShift Virtualization on the selected clusterset.
2. Ensures that a ManagedClusterBinding exists so ACM can apply policy on the targeted clusterset.
3. Creates Placement and PlacementBinding to bind the CNV installation policy to the correct clusters.
4. Waits for CNV installation to complete by verifying the HyperConverged resource.

When `CNV_POLICY_INSTALL_MAJOR_MINOR` is set, the policy pins the latest matching CSV and
version (for example latest 4.20.x on `stable`, resolved from the spoke packagemanifest) via
`startingCSV` on the `hco-operatorhub` Subscription. OLM only honors `startingCSV` on initial
subscription create, so this step also applies or remediates the spoke subscription directly
before waiting for the pinned CSV. When pinning, the policy and spoke subscription use
`installPlanApproval: Manual`; this step approves the initial InstallPlan for the pinned CSV.
After the pinned CSV is verified on the spoke, the step reasserts `Manual` so ACM policy
enforcement and OLM do not auto-upgrade CNV before a downstream CNV upgrade test step.
It then removes `startingCSV` from the spoke subscription and hub policy so OLM can create
the upgrade InstallPlan (still `Manual`). At this point OLM may resolve a multi-hop upgrade
graph — for example `4.20.3 → 4.21.0` (first hop) before `4.21.0 → 4.21.8` (final hop) —
and will immediately create a `RequiresApproval` plan for the first intermediate hop. The
downstream `PrepareCnvOlmForUpgradeTest` in the upgrade test step handles advancing through
any intermediate hops (approving and waiting for each to install) so that the final upgrade
plan for the target version is ready for `openshift-virtualization-tests` to approve.

The OLM Subscription uses metadata.name `hco-operatorhub` with spec.name `kubevirt-hyperconverged`
(standard GA CNV install), required by openshift-virtualization-tests upgrade suites.

## Requirements

1. A functional ACM hub with governance and Policy frameworks enabled.
2. oc and jq installed in the container.
3. Spoke cluster must already be installed and registered with ACM.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `CNV_POLICY_INSTALL_MAJOR_MINOR` | `""` | Pin latest CSV for this minor (e.g. `4.20`); disables auto-upgrade after install. |
| `CNV_POLICY_CHANNEL` | `stable` | OLM channel for subscription and CSV lookup. |
| `CNV_WAIT_TIMEOUT_MINUTES` | `30` | Max minutes for CNV OLM install and HyperConverged Available waits. |
| `CNV_POLL_INTERVAL_SECONDS` | `30` | Poll interval for subscription, CSV, and HyperConverged waits. |
| `CNV_POLICY_UPGRADE_APPROVAL` | `None` when pinning; else `Automatic` | After pinned install, patch subscription to `Manual` when `None`/`Manual`. |

