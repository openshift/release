# pod-scaler admission memory warning

This alert fires when the `pod-scaler admission` service determines 
that a job needs ten times more memory than is configured in its specification.
As this may indicate potential leaks, the job owner(s) should be notified.

### Useful Links
- [Prometheus Error Rate Graph](https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/monitoring/query-browser?query0=sum+by+%28workload_name%2C+workload_type%2C+determined_memory%2C+configured_memory%29+%28pod_scaler_admission_high_determined_memory%7Bworkload_type%21%7E%22undefined%7Cbuild%22%7D%29)

### Resolution
Determine the job owner(s), reach out to them and let them know of the discrepancy.