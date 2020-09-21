# periodic-branch-protector

## Insufficient permissions to update BP settings

### Symptom

```json
{
   "component":"branchprotector",
    "error":"update redhat-developer/jenkins-operator-bundle: update master from protected=false: get current branch protection: getting branch protection 404: Not Found",
    "file":"prow/cmd/branchprotector/protect.go:143",
    "func":"main.main",
    "level":"error",
    "msg":"0",
    "severity":"error",
    "time":"2020-09-21T11:38:46Z"
}
```

### Culprit

Usually caused by a new repository setting up Prow jobs. Our `branchprotector` 
has `protect-tested-repos: true` settings, which makes it attempt to set Branch
Protection for any org/repo/branch if it has at least one Prow job configured.
`branchprotector` needs `owner` permissions to read and set Branch Protection on
GitHub repositories. Our `branchprotector` uses the `openshift-merge-robot`
GH account which has the necessary permissions on most repositories, but not all
(notably ones that do not use automated merges via Tide usually do not give
the bot an `owner` permission).

### Resolution

Convince the administrator of the repository or organization to give
`openshift-merge-robot` the `owner` permissions, or disable branch protection 
setup for the repository explicitly in the configuration:

`core-services/prow/02_config/_config.yaml`:
```yaml
branch-protection:
  orgs:
    redhat-developer:
      repos:
        jenkins-operator-bundles:
          protect: false
```
