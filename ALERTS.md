# Prow alerts

A Prometheus server runs in the CI cluster and is configured to create [alerts](https://prometheus-openshift-monitoring.svc.ci.openshift.org/alerts) on top of prow metrics. By clicking on the `expr` field of every alert, we can view the query that is setup for alerting. For more information on alerts, see [the Prometheus docs](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/).

Possible reactions to some of these alerts:

## Slow operator sync

* [Slow Jenkins operator sync](https://prometheus-openshift-monitoring.svc.ci.openshift.org/graph?g0.range_input=1h&g0.expr=(sum(rate(resync_period_seconds_bucket%7Bkubernetes_name%3D%22jenkins-operator%22%2Cle%3D%229%22%7D%5B1h%5D))%20%2B%20sum(rate(resync_period_seconds_bucket%7Bkubernetes_name%3D%22jenkins-operator%22%2Cle%3D%2227%22%7D%5B1h%5D)))%20%2F%202%20%2F%20sum(rate(resync_period_seconds_count%7Bkubernetes_name%3D%22jenkins-operator%22%7D%5B1h%5D))&g0.tab=0)
* [Slow Jenkins pipeline operator sync](https://prometheus-openshift-monitoring.svc.ci.openshift.org/graph?g0.range_input=1h&g0.expr=(sum(rate(resync_period_seconds_bucket%7Bkubernetes_name%3D%22jenkins-dev-operator%22%2Cle%3D%229%22%7D%5B1h%5D))%20%2B%20sum(rate(resync_period_seconds_bucket%7Bkubernetes_name%3D%22jenkins-dev-operator%22%2Cle%3D%2227%22%7D%5B1h%5D)))%20%2F%202%20%2F%20sum(rate(resync_period_seconds_count%7Bkubernetes_name%3D%22jenkins-dev-operator%22%7D%5B1h%5D))&g0.tab=0)

These should not be a problem in general but if any of them persists for more than a couple of hours, [`max_goroutines`](https://github.com/openshift/release/blob/ff18182aa0eb849b89e7abd1bc7765ad6d27142f/cluster/ci/config/prow/config.yaml#L7) can be incremented to allow more parallelism in the operators (note that the same option dictates both operators).

It may also be that the operators are lagging due to slow responses from Jenkins. We can figure out whether prow requests to Jenkins are slow by looking at the following metrics:

* [jenkins-operator](https://prometheus-openshift-monitoring.svc.ci.openshift.org/graph?g0.range_input=12h&g0.expr=(sum(rate(jenkins_request_latency_bucket%7Bkubernetes_name%3D%22jenkins-operator%22%2Cverb%3D%22GET%22%2Cle%3D%221%22%7D%5B1h%5D))%0A%20%20%2B%20sum(rate(jenkins_request_latency_bucket%7Bkubernetes_name%3D%22jenkins-operator%22%2Cverb%3D%22GET%22%2Cle%3D%222.5%22%7D%5B1h%5D)))%0A%20%20%2F%202%20%2F%20sum(rate(jenkins_request_latency_count%7Bkubernetes_name%3D%22jenkins-operator%22%2Cverb%3D%22GET%22%7D%5B1h%5D))&g0.tab=0)
* [jenkins-dev-operator](https://prometheus-openshift-monitoring.svc.ci.openshift.org/graph?g0.range_input=12h&g0.expr=(sum(rate(jenkins_request_latency_bucket%7Bkubernetes_name%3D%22jenkins-dev-operator%22%2Cverb%3D%22GET%22%2Cle%3D%221%22%7D%5B1h%5D))%0A%20%20%2B%20sum(rate(jenkins_request_latency_bucket%7Bkubernetes_name%3D%22jenkins-dev-operator%22%2Cverb%3D%22GET%22%2Cle%3D%222.5%22%7D%5B1h%5D)))%0A%20%20%2F%202%20%2F%20sum(rate(jenkins_request_latency_count%7Bkubernetes_name%3D%22jenkins-dev-operator%22%2Cverb%3D%22GET%22%7D%5B1h%5D))&g0.tab=0)

This is the [apdex score](https://prometheus.io/docs/practices/histograms/#apdex-score) for GET request latencies from prow to Jenkins where we assume that most requests will have 1s RTT and tolerate up to 2.5s of RTT.

Another possible mitigation for slow syncs is to shard the operators further by spinning up a new deployment of [`jenkins_operator`](https://github.com/openshift/release/blob/ff18182aa0eb849b89e7abd1bc7765ad6d27142f/cluster/ci/config/prow/openshift/jenkins_operator.yaml) and tweak its [label selector](https://github.com/openshift/release/blob/ff18182aa0eb849b89e7abd1bc7765ad6d27142f/cluster/ci/config/prow/openshift/jenkins_operator.yaml#L54) to handle some of the load of the operator that experiences slow syncs. We would also need to change the label selector of the slow operator and add [labels in some of the jobs](https://github.com/openshift/release/blob/ff18182aa0eb849b89e7abd1bc7765ad6d27142f/cluster/ci/config/prow/config.yaml#L67-L68) it is handling appropriately.

Today, we use the following mappings between Jenkins operators and masters:

* `jenkins-operator` manages https://ci.openshift.redhat.com/jenkins/ via [`master=ci.openshift.redhat.com`](https://github.com/openshift/release/blob/7b6884bcd00c5674c7aa53c7e883b1e2707b564e/cluster/ci/config/prow/openshift/jenkins_operator.yaml#L54) labels.
* `jenkins-dev-operator` manages https://ci.dev.openshift.redhat.com/jenkins/ via [`master=ci.dev.openshift.redhat.com`](https://github.com/openshift/release/blob/7b6884bcd00c5674c7aa53c7e883b1e2707b564e/cluster/ci/config/prow/openshift/jenkins_operator.yaml#L132)

## Infrastructure failures

* [Errors in tests managed by jenkins-dev-operator](https://prometheus-openshift-monitoring.svc.ci.openshift.org/graph?g0.range_input=1h&g0.expr=sum(prowjobs%7Bkubernetes_name%3D%22jenkins-dev-operator%22%2Cstate%3D%22error%22%7D)%20%2F%20sum(prowjobs%7Bkubernetes_name%3D%22jenkins-dev-operator%22%7D)&g0.tab=0)
* [Errors in tests managed by jenkins-operator](https://prometheus-openshift-monitoring.svc.ci.openshift.org/graph?g0.range_input=1h&g0.expr=sum(prowjobs%7Bkubernetes_name%3D%22jenkins-operator%22%2Cstate%3D%22error%22%7D)%20%2F%20sum(prowjobs%7Bkubernetes_name%3D%22jenkins-operator%22%7D)&g0.tab=0)
* [Failed Jenkins requests from jenkins-operator](https://prometheus-openshift-monitoring.svc.ci.openshift.org/graph?g0.range_input=1h&g0.expr=sum(jenkins_requests%7Bcode!~%22%5E2..%24%22%2Ckubernetes_name%3D%22jenkins-operator%22%7D)%20%2F%20sum(jenkins_requests%7Bkubernetes_name%3D%22jenkins-operator%22%7D)&g0.tab=0)
* [Failed Jenkins requests from jenkins-dev-operator](https://prometheus-openshift-monitoring.svc.ci.openshift.org/graph?g0.range_input=1h&g0.expr=sum(jenkins_requests%7Bcode!~%22%5E2..%24%22%2Ckubernetes_name%3D%22jenkins-dev-operator%22%7D)%20%2F%20sum(jenkins_requests%7Bkubernetes_name%3D%22jenkins-dev-operator%22%7D)&g0.tab=0)

Errors in tests means that there is an underlying infrastructure failure that blocks tests from executing correctly or the tests are executing correctly but a problem in the infrastructure disallows the operators from picking up the results. Most often than not, this is an issue with Jenkins.

Failed requests to Jenkins is usually a problem with Jenkins and less often a misconfiguration in prow (eg. wrong Jenkins credentials). It may be possible that Jenkins is overwhelmed by the number of jobs it is running. In that case [`max_concurrency`](https://github.com/openshift/release/blob/ff18182aa0eb849b89e7abd1bc7765ad6d27142f/cluster/ci/config/prow/config.yaml#L6) can be decremented to force more free space in Jenkins.


### TODO: How to debug our Jenkins instances.

## Postsubmit and batch failures

* [Failures in postsubmit tests managed by jenkins-operator](https://prometheus-openshift-monitoring.svc.ci.openshift.org/graph?g0.range_input=1h&g0.expr=sum(prowjobs%7Bkubernetes_name%3D%22jenkins-operator%22%2Cstate%3D%22failure%22%2Ctype%3D%22postsubmit%22%7D)%20%2F%20sum(prowjobs%7Bkubernetes_name%3D%22jenkins-operator%22%2Ctype%3D%22postsubmit%22%7D)&g0.tab=0)
* [Failures in postsubmit tests managed by jenkins-dev-operator](https://prometheus-openshift-monitoring.svc.ci.openshift.org/graph?g0.range_input=1h&g0.expr=sum(prowjobs%7Bkubernetes_name%3D%22jenkins-dev-operator%22%2Cstate%3D%22failure%22%2Ctype%3D%22postsubmit%22%7D)%20%2F%20sum(prowjobs%7Bkubernetes_name%3D%22jenkins-dev-operator%22%2Ctype%3D%22postsubmit%22%7D)&g0.tab=0)
* [Failures in batch tests managed by jenkins-operator](https://prometheus-openshift-monitoring.svc.ci.openshift.org/graph?g0.range_input=1h&g0.expr=sum(prowjobs%7Bkubernetes_name%3D%22jenkins-operator%22%2Cstate%3D%22failure%22%2Ctype%3D%22batch%22%7D)%20%2F%20sum(prowjobs%7Bkubernetes_name%3D%22jenkins-operator%22%2Ctype%3D%22batch%22%7D)&g0.tab=0)
* [Failures in batch tests managed by jenkins-dev-operator](https://prometheus-openshift-monitoring.svc.ci.openshift.org/graph?g0.range_input=1h&g0.expr=sum(prowjobs%7Bkubernetes_name%3D%22jenkins-dev-operator%22%2Cstate%3D%22failure%22%2Ctype%3D%22batch%22%7D)%20%2F%20sum(prowjobs%7Bkubernetes_name%3D%22jenkins-dev-operator%22%2Ctype%3D%22batch%22%7D)&g0.tab=0)

These alerts are usually triggered because of [flaky tests](https://hackernoon.com/flaky-tests-a-war-that-never-ends-9aa32fdef359) but keep in mind that they may also come from infrastructure failures. The only thing that can be done in this case is to triage these failures, open issues in their respective repositories, and nag people to fix them. We need to be especially cautious about failures in batch tests. Consecutive failures in batch tests means we are not merging with a satisfying rate.

Use the following links to triage these alerts:

https://prow.svc.ci.openshift.org/?type=postsubmit

https://prow.svc.ci.openshift.org/?type=batch

TODO: Forward alerts via e-mail.
