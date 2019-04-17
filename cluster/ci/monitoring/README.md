# Monitoring

This folder contains the manifest files for monitoring CI resources. It is _assumed_ that the following CRDs
have existed already (they usually come with `openshift-monitoring`).

* prometheuses.monitoring.coreos.com
* servicemonitors.monitoring.coreos.com

## Deploy

```
$ make prow-monitoring-pre-steps
$ make prow-monitoring-deploy
```

## Clean up

```
$ make prow-monitoring-cleanup
```
