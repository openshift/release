## Alerts on the hive cluster

### hive-blocked-deprovision

#### Runbook

* Find out the name of the cluster pool that the `clusterdeployment` is from. The namespace and the name are usually the same and displayed in the alert's message
or labels of the metrics.

```console
oc --context hive get clusterdeployment -n ci-ocp-4-10-amd64-aws-us-east-1-jfrb6 ci-ocp-4-10-amd64-aws-us-east-1-jfrb6 -o json | jq '.spec.clusterPoolRef'
{
  "claimName": "a79fb333-70b5-11ed-901d-0a580a8270f1",
  "claimedTimestamp": "2022-11-30T14:07:05Z",
  "namespace": "ci-cluster-pool",
  "poolName": "ci-ocp-4-10-amd64-aws-us-east-1"
}
```

* Find out the owners of the cluster pool (they are usually the owners of the cloud account used by the cluster pool) in [clusters/hive/pools](https://github.com/openshift/release/tree/master/clusters/hive/pools) and let them be aware of the case.
The deprovision could be blocked by any of the following reasons:
    * A bug of OpenShift installer: collect the deprovision logs for the installer team to debug.
    * Something went wrong on the cloud platform: create a ticket to the cloud platform.
    * A test step that abused the cloud credentials by creating resources on the cloud with them and failing to clean them up: The owners of the cluster pools need to find the owners of the test and the steps and work with them.

* (optional) The job that claimed the cluster is stored in the label of the `clusterclaim`:

```console
oc --context hive get clusterclaims -n ci-cluster-pool a79fb333-70b5-11ed-901d-0a580a8270f1 --show-labels
NAME                                   POOL                              PENDING          CLUSTERNAMESPACE                        CLUSTERRUNNING   AGE   LABELS
a79fb333-70b5-11ed-901d-0a580a8270f1   ci-ocp-4-10-amd64-aws-us-east-1   ClusterClaimed   ci-ocp-4-10-amd64-aws-us-east-1-jfrb6   Running          91d   prow.k8s.io/build-id=1597950746676957184,prow.k8s.io/job=pull-ci-openshift-assisted-service-master-edge-subsystem-kubxxx
```

* Due to [HIVE-2191](https://issues.redhat.com/browse/HIVE-2191), the alert might be active on cluster deployments that are no longer exist on the cluster. In that case, restarting the hive-controller pod should do the job.

```console
oc --context hive get pod -n hive -l control-plane=controller-manager
NAME                                READY   STATUS    RESTARTS   AGE
hive-controllers-759f94989b-xxhh7   1/1     Running   0          74m
```
