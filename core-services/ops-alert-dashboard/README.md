# Ops alert dashboard configuration example

`_config.example.yaml` documents the required runtime configuration for the
standalone ops alert dashboard. Its placeholders are deliberately incomplete;
provision a verified copy as the required `ci/ops-alert-dashboard-config` Secret
on core-ci, key `config.yaml`. Do not commit a populated configuration or tokens.

The example stays outside the core-ci Argo CD manifest directory so it cannot
be applied as a Kubernetes resource. Deployment manifests and the prerequisite,
activation and rollback checklist are in
[`clusters/core-ci/ops-alert-dashboard`](../../clusters/core-ci/ops-alert-dashboard/README.md).
The single classification catalog remains
[`core-services/slack-bot/_ops-alerts.yaml`](../slack-bot/_ops-alerts.yaml).
