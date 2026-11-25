# Ops alert dashboard on core-ci

Run the dashboard with **one replica** and `strategy: Recreate`, after verifying
the provisioning prerequisites below. Set `replicas: 0` to stop the writer.
Keep exactly one live writer for the ops channel; never use a rolling update or
run a second live copy.

The backend and image Dockerfile come from `openshift/ci-tools-standalone`.
[Source PR #58](https://github.com/openshift/ci-tools-standalone/pull/58) must
merge and its image-publishing postsubmit must succeed before activation.
The image is `quay-proxy.ci.openshift.org/openshift/ci:ci_ops-alert-dashboard_latest`
(amd64 and arm64). This change publishes the production binary from the existing
`make production-install` image build. Confirm the published image contains the
reviewed source revision before using it; keep an immutable rollback digest.

## Resources and trust boundary

The core-ci ApplicationSet discovers `clusters/core-ci/*` and recursively loads
YAML. It will discover this directory without another ApplicationSet edit.
Configuration examples live at
[`core-services/ops-alert-dashboard/_config.example.yaml`](../../../core-services/ops-alert-dashboard/_config.example.yaml),
outside that discovery path: an underscore filename alone does not exclude YAML
from Argo CD.

The only Service port is HTTPS to OpenShift OAuth proxy. The Route uses reencrypt
TLS and redirects HTTP to HTTPS; the service CA provisions
`ops-alert-dashboard-tls`. The proxy connects over loopback, replaces forwarded
identity headers, and passes its authenticated email identity as
`X-Forwarded-Email`. For an email-shaped OpenShift username, this preserves the
full value; a plain username maps to `username@cluster.local`. Durable Slack
action records use this proxy-generated identity for attribution. The proxy
requires the user's permission to get the specific `ci/ops-alert-dashboard`
Service. The view RoleBinding uses the existing
`test-platform-ci-admins` group. With `access.authorization: proxy`, the backend
relies on this proxy authorization and requires a valid forwarded identity from
the trusted loopback proxy; individual operator entries are unnecessary. Verify
group membership and the proxy-generated identity before activation. No anonymous
access or bearer-token delegation is configured. Browser OAuth evaluates the SAR
using the user's identity; the ServiceAccount needs no cluster-wide tokenreview or subjectaccessreview grant.

The proxy session expires after twelve hours, covering an operator shift before
requiring a new login and Service SAR. Service access is checked at login, not on
every request, so revoking that permission can leave an existing session usable
for up to twelve hours. Cookie refresh stays disabled to keep that limit fixed.
Group and Service-permission changes govern operator access. Verify revocation with a new login after the existing
session expires.

The backend listens on port 8080 for pod health probes. `/healthz` is process
liveness; `/readyz` requires complete Slack replay. All application routes still
require a trusted loopback proxy and a valid authenticated identity authorized
for the Service; direct pod requests with forged identity headers must fail. The Service does not expose this port.

The ingress NetworkPolicy selects only dashboard pods and permits router traffic
to the OAuth proxy on TCP 8443. It adds no pod ingress rule for backend port 8080.
Kubelet probes from the pod's resident node remain allowed by Kubernetes network
policy semantics; the loopback identity check still protects application routes.
The policy leaves egress unchanged so DNS, Slack, GitHub, the Kubernetes/OAuth API
and Thanos remain reachable. It does not introduce external-IP allowlists.
See the [OpenShift router policy](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/network_security/network-policy)
and [Kubernetes network policy semantics](https://kubernetes.io/docs/concepts/services-networking/network-policies/).

The monitoring Role grants the ServiceAccount only `get`/`list` PrometheusRules in
`ci-monitoring`. Metrics use the fixed internal Thanos Query frontend already
used by Grafana, independently of Kubernetes API credentials. No PVC or database
is needed; Slack threads are the durable action record.

## Provisioning prerequisites

Do not commit credentials or populated private configuration. Authorized operators
must provision the following objects in **core-ci, namespace ci** through the
normal secret-management process:

- `ops-alert-dashboard-config`, required key `config.yaml`: copy the example
  outside the Git checkout and replace all placeholders. Verify workspace ID,
  ops channel ID, workspace URL, DPTP writer user and bot IDs, each producer ID,
  and public HTTPS origin. Set `access.authorization: proxy` and keep trusted proxy
  CIDRs restricted to loopback. The OAuth proxy enforces group-based Service access.
  Chai needs its verified user ID for explicit mentions. The `DPTP Bot` SHIP source uses the same user/bot IDs as the writer;
  unrelated DPTP notifications remain Orange / Other. Never trust display names.
- `ops-alert-dashboard-session`, required key `session_secret`: provision a
  fresh cryptographically random OAuth cookie secret dedicated to this app
  (32 random bytes, base64 encoded). Do not reuse another app's cookie secret.
- `slack-credentials-dptp-bot`, required key `oauth_token`: this existing Secret
  is publicly declared in `core-services/ci-secret-bootstrap/gsm-config.yaml`
  for core-ci/ci and is used by `clusters/core-ci/slack-bot/slack-bot.yaml`.
  Confirm its identity and required history/replies, `chat:write` and
  `reactions:write` permissions without printing the token. Confirm bot membership
  in the target channel. No new token or secret value is present in this PR.

The Deployment uses a rolling **48-hour** history window via
`--history-window=48h`. Older alerts and Chai reports leave the dashboard as the
window advances. Recovery reads up to 24 extra hours of parent messages so active
snoozes survive their original occurrence aging out and process restarts; these
buffer occurrences are hidden and cannot receive new actions. Verify Slack
retention covers at least 72 hours with the default settings. An optional fixed
RFC3339 `slack.cutover` can set an earliest go-live floor within that window.

Validate the completed files with the published binary's
`--validate-only --config=... --classification=...` command; it requires no Slack
token and performs no Slack calls. Validation of placeholders is not a substitute
for verifying the live identities and scopes.

The classification catalog remains the single canonical file
`core-services/slack-bot/_ops-alerts.yaml`. Prow config-updater distributes it to
`ci/ops-alert-dashboard-classification` on core-ci, key `_ops-alerts.yaml`. Adding
a map does not guarantee an unchanged source file triggers an initial copy.
Before activation, an authorized operator must seed that ConfigMap from the exact
merged catalog (or trigger and verify config-updater), then compare its contents
to the canonical file. Do not create another classification catalog in this
application directory. Catalog/config changes require a process restart.

## Activation and provisioning checklist

1. Merge the source PR and verify successful image publishing for both
   architectures. Record the image digest/source revision and rollback digest.
2. Provision and verify all three required Secrets, the service-generated TLS
   Secret and the classification ConfigMap. Verify exact Slack identities,
   channel membership, token permissions, history window and retention coverage.
3. Validate the completed configuration against the canonical catalog. Verify
   the final Route host matches `access.external_url`, OAuth redirect reference,
   trusted proxies and intended `test-platform-ci-admins` group membership.
   Verify the actual `X-Forwarded-Email` generated after authenticated SSO,
   including any `@cluster.local` mapping, for durable action attribution; never
   accept client-supplied identity headers.
   Confirm required network access to Slack, the Kubernetes API, internal Thanos
   frontend and public GitHub SOP Markdown.
4. The merged deployment requests **one** replica with `Recreate`. Creating the
   missing required Secrets allows its waiting pod to start automatically. Verify
   the published image supports `access.authorization: proxy` before merging
   the bootstrap mapping and letting it sync. Keep exactly one writer; use
   `replicas: 0` to hold or stop activation when prerequisites are not ready.
5. Verify complete archive replay and readiness, authenticated SSO access for
   group members, rejection for other users, rejection of spoofed direct-pod
   identity, secure proxy/header behavior, and the HTTPS route/certificate chain.
   Confirm the router namespace has the ingress selector label, route traffic
   reaches 8443, peer pods cannot reach backend 8080, and kubelet probes succeed.
   Check effective policies together because NetworkPolicy allow rules are
   additive; another policy must not reopen backend ingress. Verify revoking
   Service access denies a new login after the twelve-hour session expires.
   Check known Alertmanager/Prow/SHIP classifications, Chai report behavior,
   SOP preview, and the optional core-ci metrics source.
6. With an operator-approved occurrence, verify one acknowledge/undo cycle and
   one Ask Chai request in its Slack thread; confirm the actor, durable record,
   explicit Chai mention and no duplicate write on retry. Restart once and
   verify retained workflow state replays before enabling wider use. This step
   intentionally writes Slack and requires a deliberate live rollout window.

If replay is incomplete or identity/authorization checks fail, keep or restore
`replicas: 0` in Git and investigate before resuming. Preserve the Secret config,
configured history window and Slack history. Reverting the image to the recorded digest also
uses `Recreate` and one replica; a rollback must never introduce concurrent
writers. Do not delete durable Slack action records as a rollback mechanism.
