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

Possible reactions to some of these alerts:

* Slow Jenkins operator sync
* Slow Jenkins pipeline operator sync

These should not be a problem in general but if any of them persists for more than a couple of hours, [`max_goroutines`](https://github.com/openshift/release/blob/ff18182aa0eb849b89e7abd1bc7765ad6d27142f/cluster/ci/config/prow/config.yaml#L7) can be incremented to allow more parallelism in the operators (note that the same option dictates both operators).

It may also be that the operators are lagging due to slow responses from Jenkins. You can figure out whether prow requests to Jenkins are slow by looking at the following metrics:

* [jenkins-operator](https://prometheus-kube-system.svc.ci.openshift.org/graph?g0.range_input=12h&g0.expr=(sum(rate(jenkins_request_latency_bucket%7Bkubernetes_name%3D%22jenkins-operator%22%2Cverb%3D%22GET%22%2Cle%3D%221%22%7D%5B1h%5D))%0A%20%20%2B%20sum(rate(jenkins_request_latency_bucket%7Bkubernetes_name%3D%22jenkins-operator%22%2Cverb%3D%22GET%22%2Cle%3D%222.5%22%7D%5B1h%5D)))%0A%20%20%2F%202%20%2F%20sum(rate(jenkins_request_latency_count%7Bkubernetes_name%3D%22jenkins-operator%22%2Cverb%3D%22GET%22%7D%5B1h%5D))&g0.tab=0)
* [jenkins-origin-operator](https://prometheus-kube-system.svc.ci.openshift.org/graph?g0.range_input=12h&g0.expr=(sum(rate(jenkins_request_latency_bucket%7Bkubernetes_name%3D%22jenkins-origin-operator%22%2Cverb%3D%22GET%22%2Cle%3D%221%22%7D%5B1h%5D))%0A%20%20%2B%20sum(rate(jenkins_request_latency_bucket%7Bkubernetes_name%3D%22jenkins-origin-operator%22%2Cverb%3D%22GET%22%2Cle%3D%222.5%22%7D%5B1h%5D)))%0A%20%20%2F%202%20%2F%20sum(rate(jenkins_request_latency_count%7Bkubernetes_name%3D%22jenkins-origin-operator%22%2Cverb%3D%22GET%22%7D%5B1h%5D))&g0.tab=0)

This is the [apdex score](https://prometheus.io/docs/practices/histograms/#apdex-score) for GET request latencies from prow to Jenkins where we assume that most requests will have 1s RTT and tolerate up to 2.5s of RTT.

Another possible mitigation for slow syncs is to shard the operators further by spinning up a new deployment of [`jenkins_operator`](https://github.com/openshift/release/blob/ff18182aa0eb849b89e7abd1bc7765ad6d27142f/cluster/ci/config/prow/openshift/jenkins_operator.yaml) and tweak its [label selector](https://github.com/openshift/release/blob/ff18182aa0eb849b89e7abd1bc7765ad6d27142f/cluster/ci/config/prow/openshift/jenkins_operator.yaml#L54) to handle some of the load of the operator that experiences slow syncs. You will also need to change the label selector of the slow operator and add [labels in some of the jobs](https://github.com/openshift/release/blob/ff18182aa0eb849b89e7abd1bc7765ad6d27142f/cluster/ci/config/prow/config.yaml#L67-L68) it is handling appropriately.

* Errors in tests managed by jenkins-origin-operator
* Errors in tests managed by jenkins-operator
* Failed Jenkins requests from jenkins-operator
* Failed Jenkins requests from jenkins-origin-operator

Errors in tests means that there is an underlying infrastructure failure that blocks tests from executing correctly or the tests are executing correctly but a problem in the infrastructure disallows the operators to pick up the correct results. Most often than not, this is an issue with Jenkins.

Failed requests to Jenkins is usually a problem with Jenkins and less often a misconfiguration in prow (eg. wrong Jenkins credentials). It may be possible that Jenkins is overwhelmed by the number of jobs it is running. In that case [`max_concurrency`](https://github.com/openshift/release/blob/ff18182aa0eb849b89e7abd1bc7765ad6d27142f/cluster/ci/config/prow/config.yaml#L6) can be decremented to force more free space in Jenkins.

TODO: How to debug our Jenkins instances.

* Failures in postsubmit tests managed by jenkins-operator
* Failures in postsubmit tests managed by jenkins-origin-operator
* Failures in batch tests managed by jenkins-operator
* Failures in batch tests managed by jenkins-origin-operator

These alerts are usually triggered because of [flaky tests](https://hackernoon.com/flaky-tests-a-war-that-never-ends-9aa32fdef359). The only thing that can be done in this case is to triage these failures, open issues in their respective repositories, and nag people to fix them. We need to be especially cautious about failures in batch tests. Consecutive failures in batch tests means we are not merging with a satisfying rate.

Use the following links to triage these alerts:

https://deck-ci.svc.ci.openshift.org/?type=postsubmit

https://deck-ci.svc.ci.openshift.org/?type=batch

TODO: Forward alerts via e-mail.


