# Core CI Alertmanager HTTPS

Alertmanager serves HTTPS on `alertmanager-operated.ci-monitoring.svc:9093`.
The headless Service requests `Secret/alertmanager-tls` from OpenShift service-ca.
The Alertmanager resource uses that certificate and explicitly selects the same
governing Service, preserving the existing peer DNS names while Git manages the
Service configuration.

Thanos Ruler uses HTTPS and trusts the injected service CA through
`SSL_CERT_FILE`. Its object storage configuration and two-hour retention belong
under `rulerMode.stateful`, and its resource requests use `resourceRequirements`,
as required by the installed Thanos Operator CRD.

## Rollout

Deploy an alert-proxy image containing
[ci-tools-standalone PR #53](https://github.com/openshift/ci-tools-standalone/pull/53)
before changing the proxy URL. Older images reject the ci-monitoring hostname at
startup. The alert-proxy deployment mounts its own injected service CA bundle.

The Service and Ruler CA ConfigMap sync before their consumers. Confirm that
`Secret/alertmanager-tls` contains `tls.crt` and `tls.key`, and that
`ConfigMap/thanos-ruler-alertmanager-ca` has a nonempty `service-ca.crt`, before
advancing a manual rollout. Do not copy private keys or webhook credentials into
Git.

After the resources sync:

- Confirm both Alertmanager and Thanos Ruler replicas are ready, and alert-proxy
  has one ready replica.
- Confirm the `ci-monitoring` Argo Application can compare and sync without
  unknown-field errors.
- Check both Ruler logs for successful delivery without HTTP 400 or certificate
  errors. Alertmanager must contain the firing `alert-proxy-EndToEndProbe`.
- Observe the existing probe reach Slack and the proxy's
  `alert_proxy_end_to_end_deliveries_total` increase before declaring delivery
  restored. A successful readiness check alone does not establish delivery.

When adopting an existing operator-created Service, its old Alertmanager owner
reference can remain on the live object. If the Alertmanager resource is ever
deleted and recreated, verify that this Service is recreated by GitOps and that
service-ca has issued its certificate before starting Alertmanager.
