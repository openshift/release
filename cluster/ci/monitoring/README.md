# Monitoring

This folder contains the manifest files for monitoring CI resources. It is _assumed_ that [the following CRDs](https://github.com/coreos/prometheus-operator) have existed already.

* prometheuses.monitoring.coreos.com
* servicemonitors.monitoring.coreos.com

## Deploy

The deployment has been integrated into our CI system. The following commands are only for debugging:

```
$ make prow-monitoring-pre-steps
$ make prow-monitoring-deploy
```

A successful deploy will spawn a stack of monitoring for prow: _prometheus_, _alertmanager_, and _grafana_.

```
$ oc get sts -n prow-monitoring
NAME                DESIRED   CURRENT   AGE
alertmanager-prow   3         3         21d
prometheus-prow     2         2         13d
$ oc get deploy -n prow-monitoring
NAME                  DESIRED   CURRENT   UP-TO-DATE   AVAILABLE   AGE
grafana               2         2         2            2           23d
prometheus-operator   1         1         1            1           26d

```

Note that StatefulSets `alertmanager-prow` and `prometheus-prow` are controlled by `prometheus-operator`.
There is no operator controlling `grafana` deployment.

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

We create a new grafana instance for debugging and developing purpose. _Note_ that this instance could be cleaned up anytime.

```
$ make grafana-debug-deploy
### username and password will be displayed in the output.
```

Play with [the grafana instance for debugging](https://grafana-prow-monitoring-stage.svc.ci.openshift.org) which already connects to the prometheus service in prow-monitoring.

* Create the `jsonnet` file in [`mixins/grafana_dashboards`](mixins/grafana_dashboards) folder.
* Update [Makefile](./Makefile) to include the new target to generate the `json` file.
* Login [grafana-staging](https://grafana-prow-monitoring-stage.svc.ci.openshift.org) and import manually the generated `json` file until it looks satisfying.
* Push the rest of changes.

Clean up:

```
$ make grafana-debug-cleanup
```

## Use mixins

### Debugging locally

* Install required binary: See [dashboards-validation/Dockerfile](https://github.com/openshift/release/blob/master/projects/origin-release/dashboards-validation/Dockerfile) for details of installation of dependencies on a centos-based image used in our CI system. The following commands should give us a working development environment on Fedroa:

    ```
    $ sudo dnf copr enable paulfantom/jsonnet -y
    $ sudo dnf install -y jsonnet
    $ go get github.com/jsonnet-bundler/jsonnet-bundler/cmd/jb
    $ go get github.com/brancz/gojsontoyaml
    ```

* Edit `.jsonnet` in the [mixins](./mixins) folder. Add targets in [mixins/Makefile](./mixins/Makefile) to generate the targeting file in case of creating a new `.jsonnet`.

    ```
    $ make generate-mixins
    ```

## Add an alert on Prow job failures

For DPTP-developer, we can still create/edit `jsonnet`s to add more alerts. For CI-cluster users, there is a more convenient way if users want to be notified via our slack when some Prow job fails.

For example, getting notifications for `my-cool-job-name`:

* Add this snippet into [`job_failures_config.libsonnet`](./mixins/prometheus/job_failures_config.libsonnet):


    ```
    'cool-job-name': { 
        receiver: '<receiver_name>', 
        }, 
    ```

* `<receiver_name>` above has to be defined in [`config.libsonnet`](./mixins/config.libsonnet):

```
 alertManagerReceivers: { 
   '<receiver_name>': { 
     team: '<team_name>', // used as in a alert label for alertmanager's routing, should avoid using names from other teams
     channel: '#<channel_name>', // start with '#'
     notify: '<team|person_slack_user_name>', // NO @ needed 
   }, 
 }
```

* `make generate-mixins` and `git-diff` on [`prometheus_rule_prow.yaml`](./mixins/prometheus_out/prometheus_rule_prow.yaml) for the new alert. Create PR if it looks good.
