# Ops alert classification

`_ops-alerts.yaml` contains the classification exceptions and fixed source policies
for the Slack-fed operations dashboard. It is configuration data, not a Kubernetes
manifest. Prow config-updater distributes it to the dashboard's classification
ConfigMap; the dashboard loads it at startup.

Our managed Prometheus rules carry `ops_color` and `ops_category` in their alert
annotations. Their Alertmanager Slack templates publish the values as
`[ops_color=red ops_category=ci_platform]`. Direct Prow Slack reports publish the
same marker from their job or ci-operator source configuration. Alert names,
native severity, routing and paging remain independent of classification.

The consumer should use this order:

1. Recognized Chai scheduled reports are Green / Chai reports and appear only in
   the Chai reports view. Investigation replies remain in their alert thread.
2. Recognized SHIP outage notifications are always Yellow. Build Farm maps to
   Cluster fleet, and Downstream CI / CI-Config maps to Repo automation. Unknown
   SHIP components use Other. Thread updates inherit their parent's category.
3. For other alerts, use a valid source-supplied `ops_color` / `ops_category` pair.
4. For recognized Alertmanager alerts without source classification, apply the
   `platform_alerts` and then `legacy_alerts` entries in file order. Recognized
   historical DPTP alert/digest formats and Prow job identifiers use only
   `legacy_alerts`; platform globs do not apply to Prow jobs. Match exact names
   or anchored whole-identifier globs as specified by each entry.
5. Use Orange / Other when classification is absent, invalid or unmatched.

Recognize producers by the configured Slack app/bot identity and message parser,
not their display name or arbitrary human-posted markers. The allowed alert
colors are `red`, `orange` and `yellow`; Green is reserved for Chai reports. Alert
categories are `cluster_fleet`, `cloud_cleanup`, `ci_platform`, `repo_automation`
and `other`. Apply source policy before accepting a message-supplied marker.

Do not add a full duplicate list of source-owned rules to this file. Platform
definitions stay untouched; there is no `AlertRelabelConfig` in this change.
The exact-name legacy exceptions preserve classification for the Hive alert
whose owning definition has not been located and the three hosted-management
alerts whose manifest is outside every Argo CD Application source path. Keep
these exceptions until their managed source definitions are established.
Historical-only notifications without a current definition use the default.

## Markerless notifications already in the feed

The narrow legacy entries also cover observed retained notifications that were
published without classification markers: CI Operator errors, ghproxy pending
requests, Prow backlog, infrastructure-job failures, the blackbox probe, private
image-building failures, Repo Brancher digests and the listed Konflux cleanup
jobs. Their colors follow the source-owned rules/reporters. Source markers always
win, including a job-specific category on infrastructure alerts. When the old
notification omits its job labels, its infrastructure alert uses the generic
Orange / CI platform classification rather than guessing a specialized category.
Unknown identifiers still use Orange / Other. Keep this compatibility list narrow;
new producer definitions should publish their own classification.

The dashboard recognizes both Unicode and Slack's `:rotating_light:` representation
of the structural SHIP outage header. Both retain the fixed Yellow policy and
component category. A mention of an outage inside an unrelated message does not
activate that policy.

Deploy [dashboard parser PR #61](https://github.com/openshift/ci-tools-standalone/pull/61)
before relying on legacy Prow/DPTP identifier support, then restart the dashboard after the catalog ConfigMap updates. Catalog
updates alone do not reload a running process.

The checked-in Alertmanager critical template already emits the annotations, but
its generated Template must be rendered into the Secret actually selected by the
running Alertmanager. On core-ci that is `ci-monitoring/alertmanager-ci-monitoring`.
See the [monitoring configuration reconciliation instructions](../../clusters/core-ci/ci-monitoring/README.md#configuration-deployment-and-reconciliation)
when a current notification still omits markers; applying the differently named
Template object does not update that live configuration. Preserve private
receiver credentials through the normal secret-management workflow.
