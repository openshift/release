# build-cop dashboard in prow-monitoring

The [build-cop dashboard](https://grafana-prow-monitoring.svc.ci.openshift.org/d/6829209d59479d48073d09725ce807fa/build-cop-dashboard?orgId=1) in [prow-monitoring](README.md) is an alternative tool which shows the sucessful rate for varous types of prow jobs in build-cop reports. The data in metrics are obtained by scaping the related component in prow. Every authenticated user of our CI cluster has the access to dashboard.

[Prow deck](https://prow.svc.ci.openshift.org/) has been used for the similar purpose. Eg, deck page shows `Success rate over time: 3h: 78%, 12h: 81%, 48h: 77%` for job with name `*-master-e2e-aws`.

The first panel `Job Success Rates for pre-defined job names` in the dashboard shows its success rate (and other jobs related to build-cop reports) at any time point with a time-range, by default, of the last 24 hours.

Our target that _the pass rate of *-master-e2e-aws jobs over the last day should be 75% or higher_ can be satisfied if in the panel, the lowest point during the last 24 hours for `*-master-e2e-aws` is above 75%.

The other panels describe the success rates of prow jobs in our CI system with different dimention. Eg, the panel `Job States by Branch` show the rates for all `4.X` release branches.

We can also use the variables in the template on the top of the dashboard to concentrate on the `org/repo@branch` of interest. The default value `All` is `.*` in [PromQL](https://prometheus.io/docs/prometheus/latest/querying/basics/). Hovering on the "_i_" on the top-left corner of each panel shows the query used for plotting the panel.

