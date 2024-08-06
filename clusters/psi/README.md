# The mp+ cluster (formerly psi)

[The mp+ cluster](https://console-openshift-console.apps.prod-stable-spoke1-dc-iad2.itup.redhat.com/k8s/cluster/projects/ocp-test-platform--runtime-int) is hosted inside the Red Hat network.

Namespaces:
 -   --config - A tenant config namespace is where you manage most tenant resources. You should not deploy any workloads there.
 -   --pipeline - The build tenant namespace is where you create BuildConfigs and pipelines. It includes build entitlements and provides means to integrate your tenant across clusters. For security reasons, those entitlements and integrations should not be made available to your applications running in the runtime namespaces.
 -   --runtime-int -The runtime for applications running in the internal network security zone.

[The group ocp-test-platform-psi](https://rover.redhat.com/groups/group/ocp-test-platform-psi) are admins of the `ocp-test-platform` project.

This cluster is used for the TP team to run lightweight tasks which can only be performed inside the Red Hat network.


## applyconfig
Since we cannot run applyconfig as a Prowjob for the cluster, this command is used for the same goal on a PC after connecting Red Hat VPN:

```console
$ make applyconfig
```

## troubleshooting

```console
$ oc --context mpp get cronjob
NAME                         SCHEDULE    SUSPEND   ACTIVE   LAST SCHEDULE   AGE
sync-rover-groups-update     0 1 * * *   False     0        <none>          20s
$ cronjob_name=sync-rover-groups-update
$ oc --context mpp -n ocp-test-platform--runtime-int create job ${cronjob_name}-test-job-$USER-$(openssl rand -hex 6) --from=cronjob/${cronjob_name}
```
