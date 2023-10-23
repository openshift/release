## High number of HostedClusters

The symptons include:
1. tests failed to create HyperShift clusters
2. Repeated alerts as

```[FIRING:1] hive-controllers-down (hive critical)
```
```[FIRING:1] hive-clustersync-down (hive critical)
```

It is a known issue that `hive-controller` could be evicted once high number of HostedClusters are created and the `hive` cluster is scaling up.

We can check the number of HostedClusters by

```
oc --context hive -n clusters get hostedclusters | wc -l
```

If the number is greater than 80, we need to invoke our [cleaner](https://prow.ci.openshift.org/?job=periodic-openshift-dptp-3312-hypershift-leaks-cleaner) to clean the resources.

```
$ JOB=periodic-openshift-dptp-3312-hypershift-leaks-cleaner make job
```

If the number of clusters is still more than `80` once the periodic is ran, we need to manually inspect the hostedclusters to find out which job creates them (`oc --context hive -n clusters get hostedcluster <name>` and look for `annotations`), then ask the owner of the job to reduce the frequencies the job is invoked.
