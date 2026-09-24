# Alert proxy rollout

This directory describes the intended final state. The accumulated alert-proxy changes across
`ci-tools`, `ci-tools-standalone`, and `openshift/release` must not be merged or applied atomically.
The ordering and gates below are part of the safety boundary: direct Slack delivery is removed only
after the replacement path is proven, and Alertmanager mutations are enabled in a later change.

## Runtime state bootstrap

`state-bootstrap.create-once` deliberately has no `.yaml`, `.yml`, or `.json` suffix. Normal
directory-based `oc apply`, recursive resource discovery, and manifest automation therefore do not
select it. It is runtime-owned state, not a declarative resource to reconcile.

Before review and before every ordinary directory apply, verify the bootstrap cannot be selected by
the manifest suffixes used by release tooling:

```bash
if find clusters/app.ci/alert-proxy -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) -name 'state-bootstrap*' | grep -q .; then
  echo "create-once state bootstrap is selectable by ordinary manifest tooling" >&2
  exit 1
fi
```

Create it explicitly exactly once, before the Deployment is applied:

```bash
if oc --context app.ci -n ci get configmap alert-proxy-state >/dev/null 2>&1; then
  echo "alert-proxy-state already exists; stop and inspect it instead of adopting or overwriting it" >&2
  exit 1
fi
oc --context app.ci create -f clusters/app.ci/alert-proxy/state-bootstrap.create-once
```

Never use `oc apply`, `oc replace`, or `oc create --save-config` for this file. A later bootstrap
attempt must fail on `AlreadyExists`; deleting or resetting the ConfigMap discards durable Slack
outbox, idempotency, and silence-operation state. The steady-state ServiceAccount can only `get`
and `update` `ConfigMap/alert-proxy-state`; it cannot create it or write the identity-map ConfigMap.

## Staged changes

Each numbered stage is a separate pull request or separately applied patch. Do not advance until
all gates in the current stage pass.

### 0. Deploy the ci-tools forwarder

Merge and deploy the `slack-bot` changes that add the interaction and mention forwarders, with both
forwarding URLs still unset. Confirm the running image contains
`--alert-proxy-interaction-url`, `--alert-proxy-mention-url`,
`--alert-proxy-forwarder-secret-path`, and `--alert-proxy-channel-id`. Exercise an existing Slack
interaction and generic mention to prove the old handlers still work.

Do not apply the `slack-bot.yaml` changes in this release worktree before this gate. An older binary
will reject the new flags and fail to start.

### 1. Provision inert foundations

In release PR 1, land only:

- the `alert-proxy` image item in
  `ci-operator/config/openshift/ci-tools-standalone/openshift-ci-tools-standalone-main.yaml`;
- the two independent entries in `core-services/ci-secret-bootstrap/gsm-config.yaml`; and
- the second `openshift-user-workload-monitoring` target on the
  `alert-proxy-alertmanager-webhook` entry.

That second target must be synced before stage 3 adds the secret to the `alertmanager.secrets`
list. Mounting a secret that does not exist yet leaves the Alertmanager pods in
`ContainerCreating`, which is an Alertmanager outage rather than a failed rollout step.

Trigger or wait for a `ci-tools-standalone` main postsubmit after the image configuration is live,
then confirm the job's promotion step succeeded and record the digest it published. Do not gate on
`ImageStreamTag/alert-proxy:latest` in namespace `ci`: promotion targets
`quay.io/openshift/ci:ci_alert-proxy_latest`, and the app.ci `ci` imagestreams have been frozen
since 2026-08-05, so that tag never appears however many postsubmits succeed. Promotion is also
all-or-nothing, so an unrelated failure elsewhere in the job skips it while the alert-proxy build
itself is green; read the job result rather than inferring it from the build. Verify, without printing secret
values, that `Secret/alert-proxy-alertmanager-webhook` has exactly the required `url` and `token`
keys in both `ci` and `openshift-user-workload-monitoring`, and that `Secret/alert-proxy-forwarder`
has `hmac_secret`. The webhook credential must not be present in `slack-bot`; the forwarder
credential must not be supplied to Alertmanager.

### 2. Deploy the proxy without carrying Alertmanager traffic

In release PR 2:

1. Run the create-once state bootstrap above and confirm `state.json` has schema version 1 and mode
   `active`. Stop if the ConfigMap already exists or contains anything unexpected.
2. Apply `config.yaml`, `rbac.yaml`, and `deployment.yaml` from this directory.
3. Apply only the alert-proxy volume, mount, and four forwarding-flag hunks from
   `clusters/app.ci/assets/slack-bot.yaml`.

Keep `--enable-silences=false`. Wait for both Deployments to roll out. Confirm `/healthz` and
`/readyz`, confirm the Service has one ready endpoint, and confirm Prometheus has successfully
scraped `up{job="alert-proxy"} == 1` at least once.

Before continuing, run the iteration-12 release gates:

- an authenticated test webhook persists a notification snapshot and outbox work before returning
  200, while a request without the webhook bearer token returns 401;
- a fresh v1-HMAC mention envelope reaches the mention handler, while missing, expired, modified,
  or cross-endpoint credentials return 401;
- an interaction retains and passes both the original Slack signature and forwarder HMAC; and
- a pod restart recovers pending outbox work without losing or resetting `alert-proxy-state`.

### 3. Add and prove probes and watchdogs

Only after the successful scrape in stage 2, land release PR 3 containing:

- `alertmanager_alert_proxy.libsonnet` and its import before `alertmanager_routes.libsonnet`;
- the `alert-proxy` entry in `ci_absent_alerts.libsonnet` and the dedicated
  `alert_proxy_alerts.libsonnet` rules;
- `alert-proxy-alertmanager-webhook` on the `alertmanager.secrets` list in
  `openshift-user-workload-monitoring_cm.yaml`; and
- generated Alertmanager and PrometheusRule artifacts produced by the mixin Makefile at this stage.

Adding the secret to the `alertmanager.secrets` list mutates the Alertmanager StatefulSet spec, so
prometheus-operator rolls both `alertmanager-user-workload` replicas when this stage is applied.
That restart is expected and brief; it is not an incident. Confirm the rollout has completed, with
both pods Running and ready, before starting the probe and watchdog observations below.

Merging this stage does not put it into effect. ArgoCD's `app-cluster-app.ci` Application syncs
`clusters/app.ci/` recursively and applies
`mixins/prometheus_out/alertmanager-user-workload-secret_template.yaml` as a `Template` object in
namespace `openshift`. Nothing in the pipeline runs `oc process`, so `Secret/alertmanager-user-workload`
keeps whatever content it had before the merge and every receiver and route added here stays inert.
Merging and walking away leaves the probe undelivered, and because the watchdog routes are absent
too, sends `alert-proxy-EndToEndDelivery-Down` to `slack-criticals` and PagerDuty instead of the
dedicated receiver. That is exactly what happened on 2026-09-24.

Render and apply it explicitly after the merge. All four parameters are already on the cluster, so
nothing has to be fetched from Google Secret Manager by hand:

```bash
T=clusters/app.ci/openshift-user-workload-monitoring/mixins/prometheus_out/alertmanager-user-workload-secret_template.yaml
oc --context app.ci process --local -f "$T" \
  -p SLACK_API_URL="$(oc --context app.ci -n ci get secret ci-slack-api-url -o jsonpath='{.data.url}' | base64 -d)" \
  -p PAGERDUTY_INTEGRATION_KEY="$(oc --context app.ci -n ci get secret pagerduty -o jsonpath='{.data.integration_key}' | base64 -d)" \
  -p CHAI_BOT_WEBHOOK_URL="$(oc --context app.ci -n ci get secret chai-bot-alertmanager-webhook -o jsonpath='{.data.url}' | base64 -d)" \
  -p CHAI_BOT_WEBHOOK_TOKEN="$(oc --context app.ci -n ci get secret chai-bot-alertmanager-webhook -o jsonpath='{.data.token}' | base64 -d)" \
  -o yaml > rendered.yaml
```

Use `--local`. Server-side `oc process` needs `create` on `processedtemplates` in the caller's
current namespace, which cluster admins do not generally have in `default`. This template declares
no `generate: expression` parameters, so client-side rendering is equivalent.

Validate before applying, because a bad apply breaks Slack and PagerDuty delivery for every alert on
the cluster, not just for alert-proxy. Extract the `alertmanager.yaml` value from the rendered
Secret and run the pinned `amtool check-config` from stage 4 against it. Then confirm the diff
against the live Secret is purely additive — only the alert-proxy receivers and their routes, no
removals, and `slack-criticals` byte-identical — before `oc apply -f rendered.yaml`. Alertmanager
reloads within about ten seconds; confirm in the `config-reloader` container log. Delete the
rendered file afterwards: it contains all four secrets in plaintext.

The receiver deliberately uses no template parameters. The webhook URL is an in-cluster literal and
the bearer token is read with `http_config.authorization.credentials_file` from
`/etc/alertmanager/secrets/alert-proxy-alertmanager-webhook/token`, mounted by the `secrets` list
above. Nothing has to be wired into the environment of whatever applies this directory, and the
token is never interpolated into the rendered `Secret/alertmanager-user-workload`. Do not reintroduce
`required: true` parameters here: an unsatisfied one fails `oc process` for the whole template, which
stops the entire Alertmanager configuration from being applied.

Confirm the rendered routes have this order before every team/severity route:

1. `alert_proxy_probe="true"` goes only to `alert-proxy-probe` and stops, so the synthetic probe can
   never reach PagerDuty;
2. all four watchdog alert names go to the dedicated Slack receiver with `continue: true`; and
3. the same watchdog names then go to the dedicated PagerDuty receiver and stop, bypassing the
   proxy webhook entirely.

The probe rule must remain continuously firing as one stable Alertmanager group, with
`repeat_interval: 15m` on only its dedicated route. Observe at least three consecutive repeat
cycles in Alertmanager. Confirm the first delivery creates one compact Slack parent, subsequent
deliveries update that same parent rather than creating new episodes, and only after each accepted
Slack post or update does `alert_proxy_end_to_end_deliveries_total` increase. Confirm no probe
appears in PagerDuty.

Test every direct watchdog condition before cutover:

- scale the proxy to zero once, verify `alert-proxy-Singleton-Down` reaches direct Slack and
  PagerDuty without traversing the proxy, then restore the replica and readiness;
- in a controlled test, produce one authenticated malformed webhook that returns 4xx, verify
  `alert-proxy-Webhook4xx` fires from the bounded five-minute increase and uses only the direct
  watchdog receivers; and
- verify `alert-proxy-EndToEndDelivery-Down` fires after 45 minutes without a successful synthetic
  delivery and also uses only the direct watchdog receivers. Restore the probe path and verify it
  resolves; and
- use an isolated staged state/Slack failure test to retain one `phase="failed"` outbox item, verify
  `alert-proxy-SlackOutboxFailed` aggregates current failed depth and uses only the direct watchdog
  receivers, then retain it for operator diagnosis and remediation rather than deleting durable state.

Regenerate artifacts from the source present in this stage. Do not copy the accumulated final-state
generated Alertmanager file, because it already contains the stage-4 receiver cutover.

### 4. Cut over the Slack leg

Before release PR 4, render the final Alertmanager configuration with real parameters and run
`amtool check-config` against the rendered file, pinned to the Alertmanager version actually
deployed on app.ci:

```bash
oc --context app.ci -n openshift-user-workload-monitoring get alertmanager user-workload -o jsonpath='{.spec.version}'
podman run --rm -v "$PWD:/w:z" --entrypoint amtool quay.io/prometheus/alertmanager:v0.27.0 \
  check-config /w/alertmanager.yaml
```

app.ci runs Alertmanager 0.27.0, which has no `webhook_config.timeout`; it was added in 0.28 and
0.27 rejects the entire configuration with `field timeout not found in type config.plain`. The
alert-proxy webhook therefore carries no timeout and relies on the proxy answering promptly. Re-add
it only after confirming the deployed version, and only via this same check.

Verify the resolved URL is the in-cluster `/webhook/alertmanager?source=app-ci-uwm` Service URL.

Then land only the `slack-criticals` receiver change in
`alertmanager_default_receivers.libsonnet` and its regenerated artifact. The receiver must retain
`pagerduty_configs`, remove `slack_configs`, and add one webhook with `send_resolved: true`,
`timeout: 10s`, bearer authorization, and `follow_redirects: false`.

Do not cut over until the stage-3 probe has succeeded for three consecutive 15-minute cycles, its
counter increment has been observed only after Slack acceptance, the probe-only route has been
proved non-paging, and all watchdog routes have been proved independent of the proxy. The
45-minute missing-delivery rule uses a 45-minute range plus `up{job="alert-proxy"} offset 45m`, so it
does not false-page immediately when the metric is first deployed; it also requires the current
`up{job="alert-proxy"} == 1`, leaving a current process outage solely to `Singleton-Down`.

Observe an actual firing and resolved delivery, the proxy receive/outbox counters, Slack output,
and Alertmanager notification failures before declaring the cutover complete. Any unexpected 4xx
or absent Slack delivery is a rollback signal; PagerDuty remains on the unchanged receiver.

### 5. Enable silence mutations separately

Do not bundle this with stage 4. After delivery and restart recovery have been observed, complete all
iteration-12 Alertmanager API, service-CA, `alertmanagers/api` RBAC, authorization-cache, inventory,
and crash-recovery checks. Only then may a separate release PR change
`--enable-silences=false` to `true`.

That same release PR must also add `create`, and only `create`, to the
`alert-proxy-alertmanager-edit` Role in `rbac.yaml`. Until this stage the Role carries only `get`,
`list`, and `delete`, because those back silence inventory, silence read-back, and silence expiry,
which `--enable-silences` never gates and which the drain and rollback path depends on. Do not add
`update`: the Alertmanager v2 API expresses creating, extending, replacing, and broadening
suppression alike as a POST to `/api/v2/silences` carrying an optional existing id, and the proxy
issues no PUT or PATCH, so an `update` grant would never be exercised. Flipping the flag without the
`create` grant leaves every suppressing operation failing on authorization.

## Rollback

Before stage 5, restore the original `slack_configs` and remove the webhook in one receiver change,
wait for Alertmanager to reload, then unset both forwarding URLs and scale the proxy down.

After silence mutations have ever been enabled, a receiver revert alone is unsafe:

1. Set `--enable-silences=false`.
2. Stop the serving Deployment while retaining its ConfigMap and mounts. Start `alert-proxy drain`
   as the replacement and only proxy process, using the same image, ServiceAccount, volumes, and
   flags. Never run drain beside a serving replica. Drain must never submit a prepared operation
   that creates, extends, replaces, or broadens suppression; it fails that operation instead. For
   every submitted or ambiguous suppressing operation whose marker is initially absent, keep
   authenticated marker inventory running through the operation's finite deadline. If the entity
   appears late, adopt it only long enough to expire it and confirm expiry.
3. Keep the operation worker running until all of these exit conditions hold at the same time:

   - no silence operation is nonterminal, including every submitted or ambiguous deadline;
   - authenticated Alertmanager inventory reports zero pending or active proxy-owned silences; and
   - the Slack outbox is empty after applying every final control-free update.

4. Clear only group and expired-reference state through the drain procedure, restore direct Slack
   delivery, remove the webhook, and verify the Alertmanager reload.
5. Unset both forwarding URLs, then remove the now-empty runtime state and proxy resources.

If silence inventory or Slack close-out cannot be confirmed, restore direct Slack delivery but do
not delete state or stop the drain worker. Treat remaining page suppression as an active incident.
