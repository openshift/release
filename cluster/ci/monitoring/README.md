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

## Add more dashboards

Suppose that there is an App running as a pod that exposes Prometheus metrics on port `n` and we want to include it into our prow-monitoring stack.
First step is to create a k8s-service to proxy port `n` if you have not done it yet.

### Add the service as target in Prometheus

This is done via `servicemonitors.monitoring.coreos.com`. See sinker as example:

```
$ oc get servicemonitors.monitoring.coreos.com -n prow-monitoring sinker -o yaml
```

The `svc` should be available on the UI `https://prometheus-prow-monitoring.svc.ci.openshift.org/targets` after the new `servicemonitor` is created.

_Note_ that the serviemonitor has to have label `prow-app` as key (value could be an arbitrary string).

### Debugging for a new grafana dashboard

With the `oauth-proxy` container, it is not clear how to access the grafana instance as admin (email sent to the monitoring team asking about this). As a workaround, we can create a new grafana instance

```
$ make grafana-debug-deploy
### username and password will be displayed in the output.
```

Play with [the grafana instance for debugging](https://grafana-prow-monitoring-stage.svc.ci.openshift.org) which already connects to the prometheus service in prow-monitoring.
Add a dashboard manually and debug it until it looks satisfying.
Then,

* Export the dashboard and save it in this folder.
* Update [Makefile](./Makefile) and [grafana_deploy.yaml](./grafana_deploy.yaml) and test it manually.
* Update the [plugins.yaml](../config/prow/plugins.yaml) to generate the configMap.
* Push the rest of changes.

Clean up:

```
$ make grafana-debug-cleanup
```

## Use mixins

### Debugging locally

* Install required binary:

    ```
    $ go get github.com/google/go-jsonnet/cmd/jsonnet
    $ go get github.com/jsonnet-bundler/jsonnet-bundler/cmd/jb
    ```

* Edit `.jsonnet` in the [mixins](./mixins) folder. Add targets in [mixins/Makefile](./mixins/Makefile) to generate the targeting file in case of creating a new `.jsonnet`.

    ```
    $ make generate-mixins
    ```
