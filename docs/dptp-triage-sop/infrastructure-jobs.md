# Infrastructure CI Jobs

1. [`branch-ci-openshift-release-master-release-controller-annotate`](#branch-ci-openshift-release-master-release-controller-annotate)
2. [`periodic-branch-protector`](#periodic-branch-protector)
3. [`periodic-branch-protector-openshift-org`](#periodic-branch-protector-openshift-org)
4. [`periodic-org-sync`](#periodic-org-sync)

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
we often just ping `@dpp-triage` to resolve them.

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
4. Ping `@dpp-triage` to remove the user from their Peribolos configuration.
