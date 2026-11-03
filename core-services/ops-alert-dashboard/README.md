# Ops alert dashboard configuration example

`_config.example.yaml` documents the required runtime configuration for the
standalone ops alert dashboard. Its placeholders are deliberately incomplete;
provision a verified copy as the required `ci/ops-alert-dashboard-config` Secret
on core-ci, key `config.yaml`. Do not commit a populated configuration or tokens.

The example stays outside the core-ci Argo CD manifest directory so it cannot
be applied as a Kubernetes resource. Deployment manifests and the prerequisite,
activation and rollback checklist are in
[`clusters/core-ci/ops-alert-dashboard`](../../clusters/core-ci/ops-alert-dashboard/README.md).
The single classification catalog remains
[`core-services/slack-bot/_ops-alerts.yaml`](../slack-bot/_ops-alerts.yaml).

## Secret onboarding

The two dashboard Secrets are synced by `ci-secret-bootstrap` from the existing
`test-platform-infra` GSM collection, group `ops-alert-dashboard`, only to
`core-ci/ci`:

| GSM field | Kubernetes Secret | Key |
| --- | --- | --- |
| `config` | `ops-alert-dashboard-config` | `config.yaml` |
| `session-secret` | `ops-alert-dashboard-session` | `session_secret` |

Use the [Secret Manager CLI](https://docs.ci.openshift.org/architecture/cli-secret-manager/)
with your own authorized collection-owner login. Keep both input files outside
Git, in a private directory with mode `0700` and files with mode `0600`.
Validate the completed runtime configuration with the dashboard's
`--validate-only --config=... --classification=...` command before uploading it.
Generate the dedicated session value from 32 cryptographically random bytes,
base64 encoded; do not reuse another application's cookie key.

```sh
./hack/secret-manager.sh create -c test-platform-infra ops-alert-dashboard/config --from-file=/private/path/config.yaml
./hack/secret-manager.sh create -c test-platform-infra ops-alert-dashboard/session-secret --from-file=/private/path/session-secret
```

If the container UID cannot read a mode-`0600` input, run the official CLI image
with Podman `--userns=keep-id:uid=1001,gid=1001` and the same authentication and
input mounts; keep the files private.

Use `update` instead of `create` when rotating an existing field. Session-key
rotation invalidates existing browser sessions. After the bootstrap mapping is
merged, let the normal `periodic-ci-secret-bootstrap` job sync the Secrets.
Verify the destination names and keys without printing their values. Config or
session-key changes require a dashboard restart; initial Secret creation lets a
pod waiting on its required mounts continue automatically. Remove the local
input files after successful upload. The existing DPTP bot token remains in
`slack-credentials-dptp-bot`; no token copying or cluster RBAC changes are needed.

Group access uses `access.authorization: proxy`, supported by
[source PR #59](https://github.com/openshift/ci-tools-standalone/pull/59). Publish
that image before merging the bootstrap mappings for a config using this option. The OAuth proxy enforces the existing
`test-platform-ci-admins` Service permission; the forwarded identity records who
performed each action. No individual operator list is needed.
