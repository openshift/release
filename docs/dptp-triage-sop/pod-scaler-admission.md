# pod-scaler admission resource warning

This alert fires when the `pod-scaler admission` service determines 
that a job needs ten times more amount of a given resource (memory or cpu) than is configured in its specification.
As this may indicate potential leaks, the job owner(s) should be notified.

### Useful Links
- [Prometheus Error Rate Graph](https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/monitoring/query-browser?query0=sum+by+%28workload_name%2C+workload_type%2C+determined_amount%2C+configured_amount%2C+resource_type%29+%28pod_scaler_admission_high_determined_resource%7Bworkload_type%21%7E%22undefined%7Cbuild%22%7D%29)
- the Prometheus metric `pod_scaler_admission_high_determined_resource` contains information used to determine the job owner(s):
  - **workload_name** in format `<pod name>-<container name>`
  - **workload_type** is one of: 
    - step (a multi-stage step)
    - prowjob
    - build
  - **resource_type** indicates the resource in question; is either memory or cpu

### Resolution
Determine the job owner(s), reach out to them and let them know of the discrepancy.