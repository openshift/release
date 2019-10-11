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

```
$ make set-up-github-oauth
```

## Set up ci-admins

```
$ make set-up-ci-admins
```

## ClusterAutoscaler

[openshift.doc](https://docs.openshift.com/container-platform/4.1/machine_management/applying-autoscaling.html)

We use aws-region `us-east-1` for our clusters: They are 6 zones in it:

```
$ aws ec2 describe-availability-zones --region us-east-1 | jq -r .AvailabilityZones[].ZoneName
us-east-1a
...
us-east-1f

```

We set autoscaler for 3 zones where the masters are: `us-east-1a`, `us-east-1b`, and `us-east-1c`.

To generate `MachineAutoscaler`s:

```
$ make generate-machine-autoscaler
```

To set up autoscaler:

```
$ make set-up-autoscaler
```

Then we should see the pod below running:

```
$ oc get pod -n openshift-machine-api -l cluster-autoscaler=default
NAME                                          READY     STATUS    RESTARTS   AGE
cluster-autoscaler-default-576944b996-h82zp   1/1       Running   0          7m54s
```
