# pod-scaler admission memory warning

This alert fires when the `pod-scaler admission` service determines 
that a job needs ten times more memory than is configured in its specification.
As this may indicate potential leaks, the job owner(s) should be notified.

### Useful Links
- [Prometheus Error Rate Graph](https://prometheus-prow-monitoring.apps.ci.l2s4.p1.openshiftapps.com/graph?g0.expr=sum%20by%20%28error%29%20%28increase%28pod_scaler_admission_error_rate%7B%7D%5B5m%5D%29%29%20%3E%200)

### Resolution
Determine the job owner(s), reach out to them and let them know of the discrepancy.