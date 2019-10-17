# 01-Cluster

[01-Cluster](https://console-openshift-console.apps.build01.ci.devcluster.openshift.com) is an OpenShift-cluster managed by DPTP-team. It is one of the clusters for running Prow job pods.

## Installation

The aws account below is managed by DPP team with the public hosted zone (base domain for installer): `ci.devcluster.openshift.com`.

To generate `install-config.yaml` after oc-cli logs in api.ci.openshift.org:

```
make generate-install-config
...
run 'cp /tmp/install-config.yaml ~/install-config.yaml' before installation the cluster
```

Check `[install_cluster.sh](./install_cluster.sh)` to see other prerequisites for installation. _Please ensure
cluster `build01` is destroyed before installing a new one_. This is to avoid the conflicting usage of AWS resources.

To install a Openshift 4 cluster:

```
$ make install-dptp-managed-cluster
```

Post-install action:

Once we install the cluster, store the installation directory somewhere in case we need to destroy the cluster later on.
Update password of `kubeadmin` in bitwarden (searching for item called `build_farm_01_cluster `).

## OAuth provider: github

[openshift.doc](https://docs.openshift.com/container-platform/4.1/authentication/identity_providers/configuring-github-identity-provider.html#configuring-github-identity-provider)

TODO

## ClusterAutoscaler

[openshift.doc](https://docs.openshift.com/container-platform/4.1/machine_management/applying-autoscaling.html)

TODO
