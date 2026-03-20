# RHDH CI Configuration

## New Release Branch Checklist

When creating a new release branch (e.g., `release-1.11`), you must configure a release-specific Slack webhook:

1. Create a new Slack channel following the established naming scheme (see existing channels in the [Nightly Test Alerts Slack app](https://api.slack.com/apps/A08U4AP1YTY/incoming-webhooks) for reference).
2. In the same Slack app, create a new incoming webhook for the newly created channel.
3. Store the webhook URL in the vault as `SLACK_ALERTS_WEBHOOK_URL_X_Y` (e.g., `SLACK_ALERTS_WEBHOOK_URL_1_11` for `release-1.11`).
4. The `redhat-developer-rhdh-send-alert` step automatically detects the release version from `JOB_NAME` and looks for the versioned webhook file at `/tmp/secrets/SLACK_ALERTS_WEBHOOK_URL_X_Y`. If not found, it falls back to `/tmp/secrets/SLACK_ALERTS_WEBHOOK_URL`.
