# Build Cop Dashboard in prow-monitoring

The [build-cop dashboard](https://grafana-prow-monitoring.svc.ci.openshift.org/d/6829209d59479d48073d09725ce807fa/build-cop-dashboard?orgId=1) in [prow-monitoring](README.md) is an alternative tool which shows the success rate for various types of Prow jobs in Build Cop reports. The data presented by these dashboards are derived from Prow's state and persist for a month. Every authenticated user of our CI cluster has access to the dashboard.

The Build Cop must keep track of passing rates for a number of job types. Normally, this would be done by viewing a filtered list of jobs in Deck. E.g., [the deck page](https://prow.svc.ci.openshift.org/?job=*-master-e2e-aws) shows `Success rate over time: 3h: 78%, 12h: 81%, 48h: 77%` for job with name `*-master-e2e-aws`. With the dashboard, an overview of all job types can be seen with one panel.

The first panel `Job Success Rates for pre-defined job names` in the dashboard shows its success rate (and other jobs related to Build Cop reports) at any time point with a time-range, by default, of the last 24 hours.

Our target that _the pass rate of *-master-e2e-aws jobs over the last day should be 75% or higher_ can be satisfied if in the panel, the lowest point during the last 24 hours for `*-master-e2e-aws` is above 75%.

The other panels describe the success rates of Prow jobs in our CI system with different dimension. E.g., the panel `Job States by Branch` show the rates for all `4.X` release branches.

We can also use the variables in the template on the top of the dashboard to concentrate on the `org/repo@branch` of interest. The default value `All` will match anything. Hovering on the "_i_" on the top-left corner of each panel shows the query used for plotting the panel.

