# sync-rover-groups-update on core-ci

Daily job that resolves Rover groups and updates `configmap/sync-rover-groups` on app.ci. Replaces the mp+ (psi) CronJob; applied via `appset-cluster-core-ci`.

Before the job can run, create `secret/sync-rover-groups-updater-credentials` in `namespace/ci` on core-ci (kubeconfig for app.ci `ci/sync-rover-groups-updater`). The same secret content as on mp+ can be reused.

```console
oc --context core-ci -n ci create job sync-rover-groups-update-test-$(openssl rand -hex 4) --from=cronjob/sync-rover-groups-update
```
