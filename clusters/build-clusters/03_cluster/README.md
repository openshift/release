# 01-Cluster



## Installation

* create a new zone: `aws.ci.openshift.org.` on https://openshift-ci-infra.signin.aws.amazon.com/console
     The base domain for build01 is `ci.devcluster.openshift.com`. The above one looks better.

* On GCP give the ownership of `aws.ci.openshift.org.` to the above zone.

* in the installation config
 * Use the SSH public key. Same as build02.
 * Use build01 as the cluster name.
 * Use the instance type and the disk type of masters and workers (check on EC2 console)

* Set up AWS credentials (every one of us should have the admin permissions)
* Download the installer and install with the above install.config.
* Upload the installation folder to gdrive




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
The cert-based kubeconfig file is also uploaded to the same BW item (attachement `b01.admin.cert.kubeconfig`).

