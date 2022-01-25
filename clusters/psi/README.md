# The psi cluster

[The psi cluster](https://console-openshift-console.apps.ocp-c1.prod.psi.redhat.com/project-details/ns/ocp-test-platform) is hosted inside the Red Hat network.
[The group ocp-test-platform-psi](https://rover.redhat.com/groups/group/ocp-test-platform-psi) are admins of the `ocp-test-platform` project.

This cluster is used for the TP team to run lightweight tasks which can only be performed inside the Red Hat network.


## applyconfig
Since we cannot run applyconfig as a Prowjob for the cluster, this command is used for the same goal on a PC after connecting Red Hat VPN:

```console
$ make applyconfig
```

## troubleshooting

```console
$ oc --context psi get cronjob
NAME                         SCHEDULE    SUSPEND   ACTIVE   LAST SCHEDULE   AGE
github-ldap-mapping-update   0 1 * * *   False     0        14h             88d
release-schedules-update     0 1 * * *   False     0        14h             83d
sync-rover-groups-update     0 1 * * *   False     0        <none>          20s
$ cronjob_name=sync-rover-groups-update
$ oc --context psi -n ocp-test-platform create job ${cronjob_name}-test-job-$USER-$(echo $RANDOM | md5sum | head -c 8) --from=cronjob/${cronjob_name}
```
