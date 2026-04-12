# High CI Operator Error Rate

This SOP covers `high-ci-operator-error-rate` on `app.ci`.

## What this alert means

This alert fires when failed CI Operator executions exceed the configured rate threshold for a specific `reason`.
An individual trigger is not always dangerous. Repeated triggers and sustained trends are the real risk.
A high failure value for this alert can indicate an ongoing outage affecting one cluster or multiple clusters.

## Most common reasons

### `executing_graph:step_failed:building_project_image`

This usually means a project image build step failed while ci-operator was executing the step graph.
Common causes include Dockerfile/build context issues, base image/input image issues, registry pull/push errors, or transient cluster build failures.

### `executing_graph:interrupted`

This usually means graph execution was canceled/interrupted instead of naturally failing a test step.
Common causes include job cancellation, process interruption, namespace deletion, or other external stop conditions.

## Triage (actionable)

1. Open CI search from the alert and group failures by `job`, `reason`, and `cluster` in the same time window.
2. Decide if this is isolated noise or a trend:
   - isolated/short burst: monitor
   - repeated/sustained increase: treat as incident
3. Look for dominant patterns (same repo, branch, cluster, step, and failure signature).
4. Intervene based on dominant reason:
   - For `building_project_image`, inspect build pod logs/events and fix build inputs or image pipeline issues.
   - For `interrupted`, investigate cancellation causes (cluster instability, namespace churn, manual/system cancels).
5. Continue monitoring after mitigation to confirm the error-rate trend drops.
