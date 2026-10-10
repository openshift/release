# Tide Pool Stalled

## Alert binding

| Field | Value |
|-------|-------|
| **Alert** | `TidePoolStalled` |
| **Cluster** | `app.ci` while Tide runs there; the source and next generated manifest also live under `core-ci` during the monitoring migration. |
| **Source** | [`tide_alerts.libsonnet`](../../clusters/core-ci/openshift-user-workload-monitoring/mixins/_prometheus/tide_alerts.libsonnet) |
| **Deployed rule** | [`ci-alerts_prometheusrule.yaml`](../../clusters/app.ci/openshift-user-workload-monitoring/mixins/prometheus_out/ci-alerts_prometheusrule.yaml) |
| **Condition** | A fresh, non-empty Tide pool persists for four hours, with no merge for the same organization, repository, and branch. |
| **Severity** | Warning |

This alert is scoped per Tide pool. It complements `TideNotMergingPRs`, which
detects a global lack of merges but cannot identify a single blocked repository.

## Diagnose

1. Open the [Tide status page](https://prow.ci.openshift.org/tide) and locate
   `{{ $labels.org }}/{{ $labels.repo }}:{{ $labels.branch }}`.
2. Inspect the pool history for the full four-hour alert window. Look for the
   same pull request and head SHA being selected repeatedly without a merge.
3. Check the Tide logs for that repository, pull request, and SHA:

   ```bash
   ORG=<org-from-alert>
   REPO=<repo-from-alert>

   oc --context app.ci -n ci logs deploy/tide --since=5h \
     | grep -F "$ORG/$REPO" \
     | grep -E 'unmergable|merge|rule violation|405'
   ```

4. Inspect the affected pull request in GitHub. Confirm its current required
   checks, labels, approvals, mergeability, and any repository or organization
   ruleset violations.
5. Check whether other repositories are merging. If they are not, follow the
   global `TideNotMergingPRs` alert instead of treating this as a pool-specific
   problem.

## Common causes

- GitHub rejects Tide's merge request because of a branch-protection or ruleset
  condition that Tide did not evaluate before selecting the pull request.
- A required context is pending, missing, or failing.
- Required Tide labels or approvals changed while the pull request was in the
  pool.
- Tide repeatedly encounters a transient GitHub API or merge conflict error.

Tide and GitHub enforce different layers of merge policy. In particular, a
GitHub ruleset can reject the merge API request after Tide has selected a pull
request. Do not assume that membership in the Tide pool proves GitHub will
accept the merge.

## Mitigate and verify

Resolve the pull-request condition or the underlying service failure. Do not
remove a repository or organization protection rule solely to clear the alert.
If Tide configuration and GitHub policy are systematically inconsistent, make
the change through the normal configuration review process.

Verify that:

- the repeated pull request either merges or leaves the pool;
- another eligible pull request can advance; and
- `TidePoolStalled` clears after the pool empties or a merge is observed.
