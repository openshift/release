# `openshift-priv` Organization

## Unrelated histories

A force-push in one of the repositories which has a counterpart in
`openshfit-priv` will cause the job to fail to synchronize the repositories,
e.g.:

```
time="2022-11-01T08:23:40Z" level=warning msg="error occurred while fetching remote and merge" branch=release-4.13 destination=openshift-priv/cluster-api-provider-ibmcloud@release-4.13 error="[failed to merge openshift-cluster-api-provider-ibmcloud/release-4.13: failed with 128 exit-code: fatal: refusing to merge unrelated histories\n, failed to perform merge --abort: failed with 128 exit-code: fatal: There is no merge to abort (MERGE_HEAD missing).\n]" local-repo=/tmp/1970879496/openshift/cluster-api-provider-ibmcloud org=openshift repo=cluster-api-provider-ibmcloud source=openshift/cluster-api-provider-ibmcloud@release-4.13 source-file=openshift-cluster-api-provider-ibmcloud-release-4.13.yaml variant=
```
https://prow.ci.openshift.org/view/gs/test-platform-results/logs/periodic-openshift-release-private-org-sync/1587355868737835008

Because merge conflicts are [ignored][private_org_sync_readme] by
`private-org-sync`, this will not cause the synchronization job to fail;
instead, the two repositories will silently diverge.  Eventually, this will
result in support requests when the owners notice their repository has not been
updated.

Manual intervention is required to reconcile the two repositories.  For example,
to completely overwrite the private version:

```console
$ git clone --quiet --origin public https://github.com/openshift/cluster-api-provider-ibmcloud.git
$ cd cluster-api-provider-ibmcloud/
$ git remote set-url --push public '' # for safety
$ git remote add private https://openshift-merge-robot@github.com/openshift-priv/cluster-api-provider-ibmcloud.git
$ git fetch --quiet --all
$ git log --oneline -n 1 private/release-4.13
3bde969f (private/release-4.13) Merge pull request #21 from lobziik/mao-update-f76a8f3a
$ git log --oneline -n 1 public/release-4.13
5e3a2bae (public/release-4.13) Merge pull request #38 from Karthik-K-N/merge-09-10-22
$ git push --force private public/release-4.13:release-4.13
Enumerating objects: 32434, done.
Counting objects: 100% (32434/32434), done.
Delta compression using up to 8 threads
Compressing objects: 100% (17672/17672), done.
Writing objects: 100% (32434/32434), 71.48 MiB | 3.53 MiB/s, done.
Total 32434 (delta 12074), reused 31545 (delta 11683), pack-reused 0
remote: Resolving deltas: 100% (12074/12074), done.
To https://openshift-merge-robot@github.com/openshift-priv/cluster-api-provider-ibmcloud.git
 + 3bde969f...5e3a2bae public/release-4.13 -> release-4.13 (forced update)
```

[private_org_sync_readme]: https://github.com/openshift/ci-tools/blob/master/cmd/private-org-sync/README.md
