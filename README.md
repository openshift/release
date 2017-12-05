# OpenShift Release Tools

This repository contains the process tooling for OpenShift releases.

## Prow

Prerequisites:
* `ci` namespace exists
* `BASIC_AUTH_PASS` is the password for authenticating with https://ci.openshift.redhat.com/jenkins/
* `BEARER_TOKEN` is the token for authenticating with https://jenkins-origin-ci.svc.ci.openshift.org
* `HMAC_TOKEN` is used for decrypting Github webhook payloads
* `OAUTH_TOKEN` is used for adding labels and comments in Github
* `RETEST_TOKEN` is used by the retester periodic job to rerun tests for PRs
* `CHERRYPICK_TOKEN` is used by the cherrypick plugin to cherry-pick PRs in release branches

Ensure the aforementioned requirements are met and stand up a prow cluster:
```
make prow
```

For more information on prow, see the upstream [documentation](https://github.com/kubernetes/test-infra/tree/master/prow#prow).

### Prow alerts

A Prometheus server runs in the CI cluster and is configured to create [alerts](https://prometheus-kube-system.svc.ci.openshift.org/alerts) on top of prow metrics. By clicking on the `expr` field of every alert, you can view the query that is setup for alerting. For more information on alerts, see [the Prometheus docs](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/).

TODO: Forward alerts via e-mail.

TODO: Dcoument common actions on firing alerts, wherever it's possible to act
