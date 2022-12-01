# pod-scaler admission memory warning

This alert fires when the `pod-scaler admission` service determines 
that a job needs ten times more memory than is configured in its specification.
As this may indicate potential leaks, the job owner(s) should be notified.

### Useful Links
- [Prometheus Error Rate Graph](https://prometheus-prow-monitoring.apps.ci.l2s4.p1.openshiftapps.com/graph?g0.expr=sum%20by%20(workload_name%2C%20workload_type%2C%20configured_memory%2C%20determined_memory)%20(increase(pod_scaler_admission_high_determined_memory%7B%7D%5B5m%5D))%20%3E%200&g0.tab=1&g0.stacked=0&g0.show_exemplars=0&g0.range_input=1h)

### Resolution
Determine the job owner(s), reach out to them and let them know of the discrepancy.