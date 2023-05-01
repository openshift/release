# Loki Grafana

This Grafana instance is used by the Technical Release Team and various OpenShift dev teams to debug CI jobs.

## Plugins

A PVC is used for grafana-plugins so we can persist their installation across restarts. Plugins must be installed manually in the event the PVC is lost. Current list:

- Google BigQuery
