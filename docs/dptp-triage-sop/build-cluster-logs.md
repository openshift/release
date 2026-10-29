# Build cluster logs

Build cluster logs can be viewed in the [Observatorium Grafana](https://grafana-loki.ci.openshift.org/explore?orgId=1&left=%5B%22now-1h%22,%22now%22,%22Observatorium%22,%7B%7D%5D).

Keep in mind to open it in a private window and log in with your Loki SSO credentials, the default SSO credentials will not give you access.

A typical query looks something like this:

```
{cluster_name="build01"}|unpack|app="openshift-controller-manager"
```

Because of performance reasons, we can not create indexes for all labels our logs have. Instead, there is a very limited
set of labels that are allowlisted for indexing and the remaining ones are made part of the log itself. The first part of
the query above filters using an index, then the log is unpacked which allows to access the labels that were not allowlisted
which allows us to filter by them in the last part.
