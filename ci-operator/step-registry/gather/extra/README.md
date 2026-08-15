To run this script locally (for example, as a backup when [`oc adm must-gather`][must-gather] and `oc adm inspect clusterversion,clusteroperators` fail):

```console
$ export KUBECONFIG=...  # or otherwise setup 'oc' to connect to your target cluster
$ export ARTIFACT_DIR=/tmp/artifacts
$ export SHARED_DIR=/tmp/shared
$ mkdir -p "${ARTIFACT_DIR}" "${SHARED_DIR}"
$ ./gather-extra-commands.sh
```

[must-gather]: https://docs.openshift.com/container-platform/4.9/support/gathering-cluster-data.html#support_gathering_data_gathering-cluster-data
