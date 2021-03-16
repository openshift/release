# Hive

[Hive](https://github.com/openshift/hive) is used as ClusterPool API to manage clusters for CI tests.

## Deploy hive-operator via OLM
See [Hive doc](https://github.com/openshift/hive/blob/master/docs/install.md).

* Note that before installing Hive, become a cluster admin (and revoke it afterwards).

* Create `hive` project.

```bash
$ oc apply -f clusters/app.ci/hive/hive_ns.yaml
```

* After installation steps are completed via OLM UI, `hive-operator` pod is running.

```bash
$ oc get pod -n hive
NAME                            READY   STATUS    RESTARTS   AGE
hive-operator-8848d9948-q7mjq   1/1     Running   0          2m52s
```

##  Deploy Hive

Create a `HiveConfig` to create a hive deployment.

```bash
$ oc apply -f clusters/app.ci/hive/hive_hiveconfig.yaml
hiveconfig.hive.openshift.io/hive created
```

Check if the relevant pods are running.

```
oc get pod -n hive
NAME                                READY   STATUS    RESTARTS   AGE
hive-clustersync-0                  1/1     Running   0          2m16s
hive-controllers-578c8cdb45-5h94g   1/1     Running   0          2m16s
hive-operator-8848d9948-q7mjq       1/1     Running   0          13m
hiveadmission-9f7df866b-lbcmp       1/1     Running   0          2m16s
hiveadmission-9f7df866b-zb98l       1/1     Running   0          2m16s
```

## Deploy a cluster via Hive
TBU
