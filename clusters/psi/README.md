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

### version

```console
$ oc --context psi get clusterversion
NAME      VERSION   AVAILABLE   PROGRESSING   SINCE   STATUS
version   4.7.31    True        False         15d     Cluster version is 4.7.31

$ oc47 --context psi version
Client Version: 4.7.31
Kubernetes Version: v1.20.0+9689d22
```

Because of the version, `apiVersion: batch/v1beta1`, instead of `apiVersion: batch/v1`, has to be applied to `kind: CronJob`.
For the same reason, a matching version of oc-cli has to be used for triggering a cronjob manually, e.g.,

```
$ oc47 --context psi -n ocp-test-platform create job github-ldap-mapping-update-test-job-$USER-$(echo $RANDOM | md5sum | head -c 8) --from=cronjob/github-ldap-mapping-update
```
