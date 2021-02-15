# Rebalancing tests among platforms

If test volume for a given platform exceeds [the Boskos lease capacity][boskos-leases], [`jobs-failing-with-lease-acquire-timeout`](../../clusters/app.ci/prow-monitoring/mixins/prometheus_out/prometheus-prow-rules_prometheusrule.yaml) will fire.
Presubmit jobs may be rebalanced to move platform-agnostic jobs to platforms with available capacity.
Component teams may mark their presubmit jobs as platform-agnostic by configuring `as` names which exclude the platform slug (e.g. `aws`), whose absence is used as a marker of "this test is platform-agnostic".
For example, see [release#10152][release-10152].
To locate platform-specific jobs which might be good candidates for moving to the platform-agnostic pool, you can use:

```console
$ ci-operator/platform-balance/step-jobs-by-platform.py
workflows which need alternative platforms to support balancing:
  baremetalds-e2e
  ipi-aws
  ipi-aws-ovn-hybrid
  openshift-e2e-aws-csi
...
count	platform	status	alternatives	job
39	gcp	balanceable	aws,azure,vsphere	pull-ci-openshift-cluster-version-operator-master-e2e
26	aws	unknown	azure,gcp,vsphere	pull-ci-openshift-sriov-dp-admission-controller-master-e2e-aws
15	aws	unknown	azure,gcp,vsphere	pull-ci-openshift-cluster-authentication-operator-master-e2e-aws
10	aws	balanceable	azure,vsphere	pull-ci-openshift-machine-config-operator-master-e2e-ovn-step-registry
9	aws	unknown	gcp	pull-ci-openshift-cluster-samples-operator-release-4.1-e2e-aws-image-ecosystem
...
```


[boskos-leases]: https://docs.ci.openshift.org/docs/architecture/quota-and-leases/
[release-10152]: https://github.com/openshift/release/pull/10152
