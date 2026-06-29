# mpiit-enrich-tickets

Post-processes Jira tickets created by firewatch. Downloads JUnit XML from
GCS, extracts structured failure metadata, and updates tickets with granular
labels and enrichment comments. Place in the post chain after firewatch.

## Secrets

This step requires the `firewatch-tool-jira-credentials` secret from the
`test-credentials` namespace, mounted at `/tmp/secrets/jira/`.

| Key            | Description                              |
|----------------|------------------------------------------|
| `access_token` | Jira API token (PAT or service account)  |
| `email`        | Jira email for Basic auth (optional)     |

When `email` is present, the step uses Basic auth (`email:token`). Otherwise
it uses bearer token auth.

To obtain credentials for local development, request a Jira API token from
the CSPI QE team or create one at https://id.atlassian.com/manage-profile/security/api-tokens.

## Optional: Chai Bot

Set `MPIIT__CHAI_API_URL` and `MPIIT__CHAI_API_TOKEN` to enable AI-assisted
root cause analysis. The URL is validated against an allowlist of internal
Red Hat domains before any data is sent.
