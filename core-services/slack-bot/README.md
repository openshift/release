# Ops alert classification

`_ops-alerts.yaml` contains the classification exceptions and fixed source policies
for the proposed Slack-fed operations dashboard. It is configuration data, not a
Kubernetes manifest. It is not yet loaded or mounted by the deployed DPTP-bot;
the dashboard backend must implement that integration.

Our Prometheus rules carry `ops_color` and `ops_category` in their alert
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
   `platform_alerts` and then `legacy_alerts` entries in file order. Match exact
   names or anchored whole-name globs as specified by each entry.
5. Use Orange / Other when classification is absent, invalid or unmatched.

Recognize producers by the configured Slack app/bot identity and message parser,
not their display name or arbitrary human-posted markers. The allowed alert
colors are `red`, `orange` and `yellow`; Green is reserved for Chai reports. Alert
categories are `cluster_fleet`, `cloud_cleanup`, `ci_platform`, `repo_automation`
and `other`. Apply source policy before accepting a message-supplied marker.

Do not add a full duplicate list of source-owned rules to this file. Platform
definitions stay untouched; there is no `AlertRelabelConfig` in this change.
The single legacy Hive exception preserves its agreed classification until its
source owner is identified. Historical-only notifications without a current
definition use the default.
