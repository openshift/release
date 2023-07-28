# Infrastructure CI Jobs

1. [`branch-ci-openshift-release-master-release-controller-annotate`](#branch-ci-openshift-release-master-release-controller-annotate)
2. [`periodic-branch-protector`](#periodic-branch-protector)
3. [`periodic-branch-protector-openshift-org`](#periodic-branch-protector-openshift-org)
4. [`periodic-org-sync`](#periodic-org-sync)
5. [`periodic-openshift-release-fast-forward`](#periodic-openshift-release-fast-forward)
6. [`periodic-check-gh-automation`](#periodic-check-gh-automation)
7. [`periodic-openshift-release-private-org-sync`](#periodic-openshift-release-private-org-sync)

## `branch-ci-openshift-release-master-release-controller-annotate`

TODO

## `periodic-branch-protector`

This job runs [Prow `branchprotector`](https://github.com/kubernetes/test-infra/tree/master/prow/cmd/branchprotector) to
reconcile the settings of
the [GitHub Branch Protection](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/defining-the-mergeability-of-pull-requests/about-protected-branches)
based on Prow configuration. This job only manages repositories outside the `openshift` GitHub organization. For repos
in `openshift`, see [periodic-branch-protection-openshift-org](#periodic-branch-protector-openshift-org).

#### Useful Links

- [Recent executions on Deck](https://prow.ci.openshift.org/?job=periodic-branch-protector)
- [infra-periodics.yaml (ProwJob configuration)](https://github.com/openshift/release/blob/master/ci-operator/jobs/infra-periodics.yaml)
- [Branch Protection documentation on docs.ci](https://docs.ci.openshift.org/docs/architecture/branch-protection/)

### Insufficient permissions to update BP settings

#### Symptom

```json
{
  "component": "branchprotector",
  "error": "update rh-ecosystem-edge: update console-plugin-gpu: update main from protected=false: get current branch protection: the GitHub API request returns a 403 error: {\"message\":\"Resource not accessible by integration\",\"documentation_url\":\"https://docs.github.com/rest/reference/repos#get-branch-protection\"}",
  "file": "prow/cmd/branchprotector/protect.go:160",
  "func": "main.main",
  "level": "error",
  "msg": "0",
  "severity": "error",
  "time": "2022-01-12T10:37:39Z"
}
```

#### Culprit

Usually caused by a new repository setting up Prow jobs. Our `branchprotector` has `protect-tested-repos: true`
settings, which makes it attempt to set Branch Protection for any org/repo/branch if it has at least one Prow job
configured. `branchprotector` needs sufficient permissions to read and set Branch Protection on GitHub repositories.
In `periodic-branch-protector`, the `branchprotector` uses the GH App authentication, provided by the repository or
organization owners by installing the [OpenShift CI](https://github.com/apps/openshift-ci) app as instructed by
the [onboarding documentation](https://docs.ci.openshift.org/docs/how-tos/onboarding-a-new-component/#granting-robots-privileges-and-installing-the-github-app)
so when we are hitting this issue, it likely means the app was not installed in that repository or organization.

#### Resolution

1. Figure out the problematic repository from the error message
2. Use `git blame` or "History" on GitHub in [openshift/release](https://github.com/openshift/release/) to find out who
   added CI configuration for the repository. Alternatively, people in the `OWNERS` file
   under `ci-operator/config/org/repo` paths are good contacts too.
3. Reach out to the repository contacts and ask them to install the [OpenShift CI](https://github.com/apps/openshift-ci)
   app as instructed by
   the [onboarding documentation](https://docs.ci.openshift.org/docs/how-tos/onboarding-a-new-component/#granting-robots-privileges-and-installing-the-github-app)
   .
4. If the problem somehow drags on for too long, consider disabling branch protection maintenance in the Prow
   configuration for the repository and ask the repository contact to revert when the configuration is fixed:

`core-services/prow/02_config/ORGANIZATION/REPOSITORY/_prowconfig.yaml`:

```yaml
branch-protection:
  orgs:
    <ORGANIZATION>:
      repos:
        <REPOSITORY>:
          unmanaged: true
```

### `openshift-priv` repository not synced yet

### Symptom

```json
{
  "component": "branchprotector",
  "error": "update openshift-priv/cluster-api-operator: could not get repo to check for archival: status code 404 not one of [200], body: {\"message\":\"Not Found\",\"documentation_url\":\"https://docs.github.com/rest/reference/repos#get-a-repository\"}",
  "file": "prow/cmd/branchprotector/protect.go:160",
  "func": "main.main",
  "level": "error",
  "msg": "0",
  "severity": "error",
  "time": "2022-02-23T10:43:26Z"
}
```

#### Culprit

Repositories in `openshift-priv`
are [created automatically](https://docs.ci.openshift.org/docs/architecture/private-repositories/#openshift-priv-organization)
based on certain CI configuration presence, and CI configuration for them as well. CI configuration also makes
branchprotector to start managing branch protection settings. So when a CI configuration is added for a new repo,
various delays can cause the situation where branchprotector tries to interact with `openshift-priv` repository before
it is created. The sequence looks like this:

1. New repository in `openshift` organization
   is [made eligible](https://prow.ci.openshift.org/?job=periodic-prow-auto-config-brancher) for having a fork
   in `openshift-priv`
2. `periodic-prow-auto-config-brancher` (runs hourly) creates CI configuration for the fork
3. After 2), `periodic-branch-protector` (runs every six hours) starts managing branch protection on the fork
4. Parallel to 2), `periodic-auto-private-org-peribolos-sync` (runs twice a day) adds the `openshift-priv` fork to
   Peribolos config
5. After 3), `periodic-org-sync` job (runs every two hours) actually creates the `openshift-priv`

This means that after a repo is made eligible for having `openshift-priv` fork, branch-protector starts interacting with
the fork on T+7 hours, but the repo can be created in T+14 hours.

This issue is tracked in [DPTP-2216](https://issues.redhat.com/browse/DPTP-2216).

#### Resolution

Confirm that the source repository in `openshift` organization had recently added or changed its ci-operator config to
become [eligible](https://docs.ci.openshift.org/docs/architecture/private-repositories/#involved-repositories) for
an `openshift-priv` fork.

## `periodic-branch-protector-openshift-org`

This job runs [Prow `branchprotector`](https://github.com/kubernetes/test-infra/tree/master/prow/cmd/branchprotector) to
reconcile the settings of
the [GitHub Branch Protection](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/defining-the-mergeability-of-pull-requests/about-protected-branches)
based on Prow configuration. This job only manages repositories in the `openshift` GitHub organization. For repos
outside of `openshift`, see [periodic-branch-protection](#periodic-branch-protector).

#### Useful Links

- [Recent executions on Deck](https://prow.ci.openshift.org/?job=periodic-branch-protector-openshift-org)
- [infra-periodics.yaml (ProwJob configuration)](https://github.com/openshift/release/blob/master/ci-operator/jobs/infra-periodics.yaml)
- [Branch Protection documentation on docs.ci](https://docs.ci.openshift.org/docs/architecture/branch-protection/)

## `periodic-org-sync`

This job runs [Prow `peribolos`](https://github.com/kubernetes/test-infra/tree/master/prow/cmd/peribolos) to reconcile
members, teams, team membership and other properties of the `openshift`
GitHub organization based on configuration stored in private [openshift/config](https://github.com/openshift/config)
repository. We share the ownership of this job with DPP: we make sure that `peribolos` works and DPP owns the config in
[openshift/config](https://github.com/openshift/config). Most problems with this job are caused by the configuration, so
we often just ping `@triage-dpp` to resolve them.

#### Useful links

- [Recent executions on Deck](https://prow.ci.openshift.org/?job=periodic-org-sync)
- [infra-periodics.yaml (ProwJob configuration)](https://github.com/openshift/release/blob/master/ci-operator/jobs/infra-periodics.yaml)

### User renamed or removed their GitHub account

#### Symptom

```json
{
  "component": "peribolos",
  "file": "prow/cmd/peribolos/main.go:209",
  "func": "main.main",
  "level": "fatal",
  "msg": "Configuration failed: failed to configure openshift teams: failed to update Team Red Hat members: UpdateTeamMembership(111111(Team Name), some-user, false) failed: status code 404 not one of [200], body: {\"message\":\"Not Found\",\"documentation_url\":\"https://docs.github.com/rest/reference/teams#add-or-update-team-membership-for-a-user\"}",
  "severity": "fatal",
  "time": "2022-01-25T12:53:32Z"
}
```

#### Culprit

Someone renamed or deleted their GitHub account and now our config is stale, trying to add a nonexistent GitHub user to
a team, organization or something similar.

#### Resolution

1. Identify the failing operations and entities involved:`UpdateTeamMembership(111111(Team Name), some-user, false)`
   means `peribolos` tried to set membership of user `some-user` in a team `Team Name`.
2. The status code hints about what kind of error was encountered: `status code 404 not one of [200]` hints that one of
   the entities was not found (and so likely does not exist).
3. Confirm the existence of `some-user` by visiting https://github.com/some-user
4. Ping `@triage-dpp` to remove the user from their Peribolos configuration.


## `periodic-openshift-release-fast-forward`

This job runs [repo-brancher](https://github.com/openshift/ci-tools/tree/master/cmd/repo-brancher) in `fast-forward` mode
in an attempt to fast-forward git content from the current development branch to the future branches if they already exist.

#### Useful links

- [Recent executions on Deck](https://prow.ci.openshift.org/?job=periodic-openshift-release-fast-forward)
- [infra-periodics.yaml (ProwJob configuration)](https://github.com/openshift/release/blob/master/ci-operator/jobs/infra-periodics.yaml)

### Attempt to push non fast-forward commit

#### Symptom

```
level=error msg="Failed to execute command." branch=master commands="git push https://openshift-merge-robot:xxx@github.com/<some-org>/<some-repo> FETCH_HEAD:refs/heads/release-4.11" future-branch=release-4.11 org=<some-org> output="To https://github.com/<some-org>/<some-repo>\n ! [rejected]        FETCH_HEAD -> release-4.11 (fetch first)\nerror: failed to push some refs to 'https://github.com/<some-org>/<some-repo>'\nhint: Updates were rejected because the remote contains work that you do\nhint: not have locally. This is usually caused by another repository pushing\nhint: to the same ref. You may want to first integrate the remote changes\nhint: (e.g., 'git pull ...') before pushing again.\nhint: See the 'Note about fast-forwards' in 'git push --help' for details.\n" repo=<some-repo> source-file=<some-yaml-config>
level=error msg="Could not push branch even with retries." branch=master future-branch=release-4.11 org=<some-org> repo=<some-repo> source-file=<some-yaml-config>
```

#### Culprit

The repo is in a bad state where someone has pushed directly to the future release branch.

#### Resolution

1. Identify the owner(s) of the repo
2. Reach out and tag them in `#forum-ocp-testplatform` asking them to clean up the affected branch.
3. This job runs hourly, so silencing the alert until they can clean it up is a good idea. 


## `periodic-check-gh-automation`

This job runs [`check-gh-automation`](https://github.com/openshift/ci-tools/tree/master/cmd/check-gh-automation) in order 
to verify that all repos with CI configured are accessible by our automation. It checks that `openshift-merge-robot` and `openshift-ci-robot`
are collaborators in each repo that has a directory in the [prow config](https://github.com/openshift/release/tree/master/core-services/prow/02_config).

#### Useful Links

- [Recent executions on Deck](https://prow.ci.openshift.org/?job=periodic-check-gh-automation)
- [infra-periodics.yaml (ProwJob configuration)](https://github.com/openshift/release/blob/master/ci-operator/jobs/infra-periodics.yaml)
- [Granting Robots Permissions on CI Docs](https://docs.ci.openshift.org/docs/how-tos/onboarding-a-new-component/#granting-robots-privileges-and-installing-the-github-app)

### 403 error when checking collaborators on a repo

If there is a 403 error in the logs it likely means that our app (`openshift-ci`) is not installed in that repo.

#### Resolution

Reach out to the owner(s) of the repo and ask them to install the app. You should also remind them to invite the bots at the same time.

### Job fails with one or more repo inaccessible

When the job fails, it will list all repos that are inaccessible by the bots at the end.

#### Resolution

Reach out to the owner(s) for each
repo listed asking them to grant the bots permissions by following the docs.

If there is argument that they do not want the bots to be added to a repo or org, it can be passed to the job as an
additional `ignore` parameter.

## `periodic-openshift-release-private-org-sync`

This job runs [`private-org-sync`](https://github.com/openshift/ci-tools/tree/master/cmd/private-org-sync) to
sync `openshift-priv`
mirror repos with their respective "public" repos.

#### Useful Links

- [Recent executions on Deck-Internal](https://deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com/?job=periodic-openshift-release-private-org-sync)
- [infra-periodics.yaml (ProwJob configuration)](https://github.com/openshift/release/blob/master/ci-operator/jobs/infra-periodics.yaml)

### Failed to push to destination

#### Symptom

```
level=error msg="failed to push to destination, no retry possible" branch=release-4.14 destination=openshift-priv/file-integrity-operator@release-4.14
error="" exit-code=1 local-repo=/tmp/1719126826/openshift/file-integrity-operator org=openshift output="To https://github.com/openshift-priv/file-integrity-operator\n
6e4fa791..c5b715ed  FETCH_HEAD -> release-4.14\n ! [rejected]          
v1.2.0 -> v1.2.0 (already exists)\nerror: failed to push some refs to 'https://github.com/openshift-priv/file-integrity-operator'\n
hint: Updates were rejected because the tag already exists in the remote.\n"
```

#### Culprit

The private mirror repo already contains a tag that the tool is attempting to mirror to it from the public repo.
This could be due to a tag being created, and then subsequently deleted and re-created in the public repo.

#### Resolution

Reach out to the repo owner(s) to confirm that this is the case. If they have the permissions, they can delete the tag
in
the private repo themselves. Otherwise, utilize the bot account to delete the tag.

## `periodic-image-mirroring-supplemental-ci-images`
This job [mirrors external images to the CI registry](https://docs.ci.openshift.org/docs/how-tos/external-images/) `registry.ci.openshift.org`.

### Symptom

```
 error: unable to push manifest to registry.ci.openshift.org/ci/prom-metrics-linter:v0.0.2: errors:
manifest blob unknown: blob unknown to registry
```

#### Culprit
The image data might be corrupted somehow.

#### Resolution
Mirror the broken image(s) manually with `--force`:

```console
$ oc --context app.ci -n ci extract secret/registry-push-credentials-ci-central --to=/tmp --keys .dockerconfigjson --confirm
/tmp/.dockerconfigjson

### find the source and destination of the mirroring
$ rg registry.ci.openshift.org/ci/prom-metrics-linter:v0.0.2 ./core-services 
./core-services/image-mirroring/supplemental-ci-images/mapping_supplemental_ci_images_ci
100:quay.io/kubevirt/prom-metrics-linter:v0.0.2 registry.ci.openshift.org/ci/prom-metrics-linter:v0.0.2

$ oc image mirror --keep-manifest-list --skip-multiple-scopes --force --registry-config /tmp/.dockerconfigjson quay.io/kubevirt/prom-metrics-linter:v0.0.2 registry.ci.openshift.org/ci/prom-metrics-linter:v0.0.2
```
