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

The Service and Ruler CA ConfigMap sync before their consumers. Confirm that
`Secret/alertmanager-tls` contains `tls.crt` and `tls.key`, and that
`ConfigMap/thanos-ruler-alertmanager-ca` has a nonempty `service-ca.crt`, before
advancing a manual rollout. Do not copy private keys or webhook credentials into
Git.

After the resources sync:

- Confirm both Alertmanager and Thanos Ruler replicas are ready.
- Confirm the `ci-monitoring` Argo Application can compare and sync without
  unknown-field errors.
- Check both Ruler logs for successful delivery without HTTP 400 or certificate
  errors.
- Verify critical notifications reach `#ops-testplatform` directly and PagerDuty
  delivery still works. Warnings continue to `#alerts-testplatform`; team routes
  and the chai-bot webhook are unchanged. Readiness alone does not prove delivery.

When adopting an existing operator-created Service, its old Alertmanager owner
reference can remain on the live object. If the Alertmanager resource is ever
deleted and recreated, verify that this Service is recreated by GitOps and that
service-ca has issued its certificate before starting Alertmanager.

## Retiring alert-proxy safely

Removal from Git is not an operational drain. Coordinate retirement **before
merging the resource and credential removal**: the deployed proxy enabled silence
mutations, so changing the receiver alone does not clear existing page suppression.
Retain the deployed image, ServiceAccount, RBAC, credentials, mounts and runtime
state until the drain has completed. Image publication in ci-tools-standalone CI
is intentionally retained so the drain image remains available.

1. Set `--enable-silences=false` on the serving proxy. Stop that Deployment while
   retaining its state and mounts, and run `alert-proxy drain` as its replacement
   and the only proxy process, with the same image, ServiceAccount, volumes and
   flags. Never run drain alongside a serving replica.
2. Drain must fail prepared operations that would create, extend, replace or
   broaden suppression rather than submit them. For submitted or ambiguous
   operations whose marker is initially absent, keep authenticated marker
   inventory running through each finite deadline; if an entity appears late,
   adopt it only to expire it and confirm expiry.
3. Keep the drain worker running until all silence operations are terminal,
   including submitted or ambiguous deadlines; authenticated Alertmanager
   inventory reports zero pending or active proxy-owned silences; and the Slack
   outbox is empty after every final control-free update.
4. Clear only group and expired-reference state through drain. Restore direct
   Slack delivery and remove the proxy webhook from the actual Alertmanager
   configuration Secret, then verify a successful reload and notification
   delivery. Only then disable Slack-bot forwarding and retire the backend,
   proxy-only token mounts, RBAC, credentials and now-empty runtime state.

If authenticated silence inventory or Slack close-out cannot be confirmed,
restore direct Slack delivery but **do not delete state or stop the drain worker**.
Treat remaining page suppression as an active incident. The runtime-owned
`ci/alert-proxy-state` ConfigMap must never be reset by applying an empty bootstrap
object; retain it for recovery until retirement is confirmed.

### Configuration deployment and reconciliation

Argo CD applies the generated Alertmanager `Template` as a Template object; it
does not process it into a Secret. Deploy the rendered configuration securely to
the Secret actually selected by each Alertmanager, validate with the appropriate
`amtool check-config` (the historical app.ci rollout used v0.27.0), and confirm
reload **before** removing the proxy token mount or backend. Never commit or log
rendered credentials; delete temporary rendered Secret files after use.

For app.ci the Template emits `alertmanager-user-workload` in
`openshift-user-workload-monitoring`. Core-ci's Alertmanager resource selects
`ci-monitoring/alertmanager-ci-monitoring`, while the generated Template still
emits a Secret named `alertmanager-user-workload`. This pre-existing naming
discrepancy is not changed by retirement: verify the consumer's actual Secret and
explicitly deploy the configuration there, rather than assuming applying the
Template updates it.

Merged [PR #87679](https://github.com/openshift/release/pull/87679) removed the
stale app.ci proxy rules and aligned the shared source namespace default with
the published core-ci output. This retirement retains that fix and uses the
shared generator directly. The separate Secret-name discrepancy described above
is not resolved by a namespace-default change.

Removing mounts changes the Alertmanager StatefulSet and may roll its replicas.
Wait for both replicas to become ready and verify direct Slack and PagerDuty
delivery, not just configuration validity.

The app.ci ApplicationSet enables automatic pruning and self-healing. The
core-ci ApplicationSet enables automatic sync but disables pruning and
self-healing. Deleting the proxy directory also removes an ApplicationSet
generator entry: verify Application deletion/cascade behavior before merge;
disabled resource pruning alone does not guarantee runtime state is retained.
`PruneLast` does not coordinate a drain or ordering between Applications. Resource
deletion from Git is not evidence that live resources, synced Secrets or backing
secret-store entries were deleted. Coordinate cleanup only after drain and
configuration cutover, including removal of obsolete proxy alerts and probes.
