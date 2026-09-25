**Attention:** These instructions should no longer be routinely needed because the
[status-reconciler](https://github.com/kubernetes/test-infra/tree/master/prow/cmd/status-reconciler)
now performs the necessary actions automatically and the queue should never become blocked.

This document is kept here in case of need for a manual intervention.

## Merge Blocking

Adding, removing or renaming merge-blocking status in a test configuration may result in a merge queue that is stuck unless manual steps with the [migratestatus](https://github.com/kubernetes/test-infra/tree/master/maintenance/migratestatus) or [commenter](https://github.com/kubernetes/test-infra/tree/master/robots/commenter) tools are taken.
Only the pull requests that are already opened will be affected.

### Add
When a new prow job is added, you can include the new status check in all the PRs:

```console
 commenter --query "repo:$org/$repo is:pr" --token $token --comment "/test $prowjob-name" --ceiling 0 --alsologtostderr --confirm
```

### Remove
While removing a required prow job, the pull requests will still await the removed job to be completed. You can solve this issue by retiring the status check context:

```console
$ migratestatus --org $org --repo $repo --tokenfile $token --retire $prowjob-name --dry-run false --alsologtostderr
```

### Rename
While renaming a required prow job, the pull requests will still await the old job to be completed. You can retire the old status check and create a new with the correct name:

```console
$ migratestatus --org $org --repo $repo --tokenfile $token --move $old-prowjob-name --dest $new-prowjob-name --dry-run false --alsologtostderr
```
