# pod-scaler admission memory warning

This alert fires when the `pod-scaler admission` service determines 
that a job needs ten times more memory than is configured in its specification.
As this may indicate potential leaks, the job owner(s) should be notified.

### Useful Links
- TODO

### Resolution
Determine the job owner(s), reach out to them and let them know of the discrepancy.