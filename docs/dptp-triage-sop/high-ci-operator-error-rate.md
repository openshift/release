# High CI Operator Error Rate

This SOP covers `high-ci-operator-error-rate` on `app.ci`.

## What this alert means

This alert fires when failed CI Operator executions exceed the configured rate threshold for a specific `reason`.
An individual trigger is not always dangerous. Repeated triggers and sustained trends are the real risk.
A high failure value for this alert can indicate an ongoing outage affecting one cluster or multiple clusters.

## Two common reasons and what they usually mean

### `executing_graph:step_failed:building_project_image`

This usually means a project image build step failed while ci-operator was executing the step graph.
Common causes include Dockerfile/build context issues, base image/input image issues, registry pull/push errors, or transient cluster build failures.

### `executing_graph:interrupted`

This usually means graph execution was canceled/interrupted instead of naturally failing a test step.
Common causes include job cancellation, process interruption, namespace deletion, or other external stop conditions.

## Actions

1. Observe which jobs/tests are failing in CI search and group by job/reason/time.
2. Look for patterns (same repo, same branch, same cluster, same step, same time window).
3. Intervene when a clear pattern appears:
   - For `building_project_image`, inspect build pod logs/events and fix build inputs or image pipeline issues.
   - For `interrupted`, investigate cancellation causes (cluster instability, namespace churn, manual/system cancels).
4. Continue monitoring after changes to confirm the trend is reduced.
