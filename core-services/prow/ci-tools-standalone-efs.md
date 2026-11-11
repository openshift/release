# ci-tools-standalone jobs on EFS

`openshift/ci-tools-standalone@main` is enrolled in `_managed-repos.yaml`.
Its ci-operator configurations remain in Git, including the `agentic` variant.
`make jobs`, generated-config validation, and auto-config-brancher skip its
Git job shards.

`branch-ci-openshift-release-main-prowgen-ci-tools-standalone` runs on app.ci
when its configurations, the step registry, enrollment, or publisher changes.
It fetches the latest release/main before generating, so a delayed or retried
job does not republish its triggering revision. `max_concurrency: 1` serializes
executions of this publisher.

The job uses the existing auto-config-brancher image and the `job-configs-nfs`
PVC. It runs without a Kubernetes service account token. The publisher generates
the main configuration and every `main__*` variant into a fresh hidden directory
on EFS. After generation succeeds, it renames the three main job shards into
`generated/openshift/ci-tools-standalone/`, removing an owned shard if its job
type no longer exists. Rebuilding the candidate also removes deleted tests.
Each replacement is atomic; the three-file update is not a transaction.
No other repository or branch is modified.

Prow components read the Git and EFS job trees. The external Prow scheduler
assigns execution clusters; this publisher does not run the Git sanitizer.

## Cutover

Prepare the EFS job shards from the reviewed cutover revision before merging
the removal of the Git shards. Use the publisher script with an app.ci pod
mounting `job-configs-nfs`, and validate the combined candidate consisting of
the cutover Git tree and the generated EFS shards. Publishing before the merge
temporarily exposes duplicate names to components still reading the old Git
tree; they must retain their last valid configuration until their Git checkout
advances. Keep the PR in draft until this coordinated cutover is ready.

After merge, verify that Git synchronization has advanced past the cutover,
all Prow config readers accept the combined tree, and the publisher succeeds.
Confirm the main presubmits, image postsubmit, and both agentic periodics are
present with their existing names. Exercise a normal standalone presubmit and
verify that the dispatcher selects an appropriate execution cluster.

## Local preview

From the release checkout, point the publisher at an empty local directory:

```sh
podman run --rm -v "$PWD:/release:z" -v /tmp/standalone-efs:/mnt/job-configs:z \
  --workdir /release --entrypoint /bin/bash \
  quay.io/openshift/ci-public:ci_auto-config-brancher_latest \
  hack/publish-ci-tools-standalone-jobs.sh /mnt/job-configs
```

Create `/tmp/standalone-efs` first. Validate the preview together with
`ci-operator/jobs` using Prow checkconfig with both `--job-config-path` values.

## Rollback

Remove the main enrollment entry, restore the three Git shards with `make jobs`,
and remove this publisher postsubmit and its script before merging the rollback.
Removing the script also prevents a queued publisher from writing after it
fetches the rollback revision. Coordinate
removal of the three EFS shards with the Git synchronization, checking that
components retain a valid configuration throughout. Preserve other EFS jobs.
