# 01-Cluster

[01-Cluster](https://console-openshift-console.apps.build01.ci.devcluster.openshift.com) is an OpenShift-cluster managed by DPTP-team. It is one of the clusters for running Prow job pods.

## Installation

The aws account for installation of this cluster: [aws console](https://openshift-ci-infra.signin.aws.amazon.com/console).

The aws account is managed by [DPP team](https://issues.redhat.com/browse/DPP-3283) with the public hosted zone (base domain for installer): `ci.devcluster.openshift.com`.

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

## Prow Configuration for build cluster

### Deploy admin assets: Manual
Deploy `./**/admin_*.yaml`.

### Deploy non-admin assets
Automated by [branch-ci-openshift-release-master-build01-apply](https://github.com/openshift/release/blob/0ac7c4c6559316a5cf40c40ca7f05a0df150ef8d/ci-operator/jobs/openshift/release/openshift-release-master-postsubmits.yaml#L9) and [Prow's config-updater plugin](https://github.com/openshift/release/blob/0ac7c4c6559316a5cf40c40ca7f05a0df150ef8d/core-services/prow/02_config/_plugins.yaml#L198).

## CA certificates: Semi-Manual

It is semi-manual because rotation of the CAs is automated and patching to config (needed only once) is not.

* API server CA: see [readme](../openshift-apiserver/README.md)

* App domain: see [readme](../openshift-ingress-operator/README.md)

### update BW items: Semi-Manual

The item `build_farm` contains
	
* `sa*config`: those are `kubeconfig` for different `SAs`
* `build01_ci_reg_auth_value.txt` and `build01_build01_reg_auth_value.txt` are used to form pull secrets for `ci-operator`'s tests.

Use [generate-bw-items.sh](./hack/generate-bw-items.sh) to generate those files, and upload them to the BW item `build_farm`.

### Populate secrets on build01 for prow and tests

Use [ci-secret-bootstrap](../../../core-services/ci-secret-bootstrap/README.md).

## OpenShift Image Registry: Manual

* Expose registry service: see [readme](../openshift-image-registry/README.md). We need to run the command only once.

## OpenShift-Monitoring

It is automated by config-updater:

* alertmanager secret for sending notification to slack
* PVCs for monitoring stack

## Upgrade the cluster

### Updating between minor versions

Upgrade channel configuration, e.g., from OCP 4.3 to 4.4:

```
oc --as system:admin --context build01 patch clusterversion version --type json -p '[{"op": "add", "path": "/spec/channel", "value": "candidate-4.4"}]'
```

### Run the upgrade command

Choose on the [release page](https://openshift-release.svc.ci.openshift.org/) the version to upgrade to, for example
[4.4.0-rc.12](https://openshift-release.svc.ci.openshift.org/releasestream/4-stable/release/4.4.0-rc.12):

```
$ bash clusters/build-clusters/01_cluster/hack/upgrade-cluster.sh quay.io/openshift-release-dev/ocp-release:4.4.0-rc.12-x86_64
--as system:admin --context build01 adm upgrade --allow-explicit-upgrade --to-image quay.io/openshift-release-dev/ocp-release@sha256:674200aaa1cc940782aa4b109ebfeaf7206bb57c3e01d62ec8e0b3d5ca910e8f
```

Double-check the SHA with:

```
$ curl -s https://mirror.openshift.com/pub/openshift-v4/clients/ocp/4.4.0-rc.12/release.txt | grep Pull
Pull From: quay.io/openshift-release-dev/ocp-release@sha256:674200aaa1cc940782aa4b109ebfeaf7206bb57c3e01d62ec8e0b3d5ca910e8f
```

Then, run the script with `DRY_RUN=false`:

```
DRY_RUN=false bash clusters/build-clusters/01_cluster/hack/upgrade-cluster.sh quay.io/openshift-release-dev/ocp-release:4.4.0-rc.12-x86_64
```

## Destroy the cluster

_Note_: [Remove the build01 config from plank](https://github.com/openshift/release/pull/6922). It would cause plank to crash otherwise.

Before recreating `build01` cluster, we need to destroy it first.

```bash
### Assume you have aws credentials file ${HOME}/.aws/credentials ready for ci-infra account
### google drive folder shared within DPTP-team
### download/unzip/cd ./build01/20191016_162227.zip
$ openshift-install destroy cluster --log-level=debug
```