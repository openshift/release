# Blackbox Probe Service Failing

This alert means the blackbox probe cannot successfully reach one of the monitored service endpoints.

The probe checks the service list configured in:
- [`blackbox_probe.yaml`](../../clusters/app.ci/openshift-user-workload-monitoring/blackbox_probe.yaml)

## Symptom
- `ProbeFailing` (strict): the probe has been failing for at least 1 minute.
- `ProbeFailing-Lenient`: the probe has been failing for at least 5 minutes.

The alert includes the failing service URL in `{{ $labels.instance }}`.

## Resolution
1. Open the failing service URL from the alert and verify if it is reachable.
2. Check if the service itself is down, degraded, or returning unexpected status codes.
3. If the service is healthy in a browser, investigate networking/DNS/TLS issues between the prober and the service, consider also tunning alert.
4. If the service is intentionally unavailable or no longer needed, update `blackbox_probe.yaml` accordingly.
5. If this is a real outage, notify the relevant service owners and track remediation.
