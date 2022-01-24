# Infrastructure CI Jobs

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
