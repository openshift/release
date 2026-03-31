# High CI Operator Infra Error Rate

This alert fires when CI Operator failures with one infrastructure-like `reason` stay above the configured rate.

## Why it is failing

Most common reasons are:
- `executing_graph:step_failed:creating_release_images`
- `executing_graph:step_failed:tagging_input_image`
- `executing_graph:step_failed:building_project_image:pod_pending`
- `executing_graph:step_failed:utilizing_cluster_claim:acquiring_cluster_claim`
- `executing_graph:step_failed:importing_release`

## Possible mitigations

1. Open CI search from the alert and identify the dominant `reason`.
2. For image/release reasons (especially `creating_release_images`, but also `tagging_input_image`, `importing_release`): check if there is possibility to fix image/tag/manifest or import issues, then retrigger affected jobs.
3. Other issues are more rare and require deeper investigation

