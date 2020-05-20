# 01-Cluster

[02-Cluster](https://console-openshift-console.apps.build02.gcp.ci.openshift.org) is an OpenShift-cluster managed by DPTP-team. It is one of the clusters for running Prow job pods.

## Installation

The gcp project `openshift-ci-build-farm` for installation of this cluster: [gcp console](https://console.cloud.google.com/home/dashboard?project=openshift-ci-build-farm). The project is created by [DPP team](hhttps://issues.redhat.com/browse/DPP-4926).

We created the public zone (base domain for installer) and the service account `ocp-cluster-installer`.
Since this project is dedicated for build farm. We granted the `Owner` role to this account.

Get the pull secret by `oc get secret -n ci cluster-secrets-gcp -o jsonpath='{.data.pull-secret}' | base64 -d`.

Generate `install-config.yaml` (uploaded to BW already for reuse): 

```
./openshift-install create install-config
? SSH Public Key /Users/hongkliu/.ssh/id_rsa_build02.pub
? Platform gcp
? Service Account (absolute path to file or JSON content)
/Users/hongkliu/Downloads/build02.install/openshift-ci-build-farm-64e4ce412ae3.json
INFO Saving the credentials to "/Users/hongkliu/.gcp/osServiceAccount.json"
? Project ID openshift-ci-build-farm
? Region us-east1
INFO Credentials loaded from file "/Users/hongkliu/.gcp/osServiceAccount.json"
? Base Domain gcp.ci.openshift.org
? Cluster Name build02
? Pull Secret
```

Customize machine type in the `install-config.yaml`:

|         | master         | worker         |
|---------|----------------|----------------|
| api.ci  | n1-standard-16 | n1-standard-16 |
| build01 | m5.2xlarge     | m5.4xlarge     |
| build02 | n1-standard-8  | n1-standard-16 |


Because of [bz1831838](https://bugzilla.redhat.com/show_bug.cgi?id=1831838), we have to modify the disk size on the _manifests_:

|         | master                   | worker                   |
|---------|--------------------------|--------------------------|
| api.ci  | 150G SSD persistent disk | 300G SSD persistent disk |
| build01 | 150G EBS gp2             | 700G EBS gp2             |
| build02 | 150G SSD persistent disk | 300G SSD persistent disk |


```
$ ./openshift-install create manifests

$ find . -name "*machines*"
./openshift/99_openshift-cluster-api_worker-machineset-0.yaml
./openshift/99_openshift-cluster-api_worker-machineset-1.yaml
./openshift/99_openshift-cluster-api_master-machines-2.yaml
./openshift/99_openshift-cluster-api_master-machines-0.yaml
./openshift/99_openshift-cluster-api_master-machines-1.yaml
./openshift/99_openshift-cluster-api_worker-machineset-2.yaml
```

Then,

> ./openshift-install create  cluster --log-level=debug

The secrets have been uploaded to BitWarden item `build_farm_02_cluster`:

* the key file for the service account `ocp-cluster-installer`
* the SSH key pair (`id_rsa` and `id_rsa.pub`)
* install-config.yaml.001 (the one with the desired instance type)
* The auth info for `kubeadmin`

The installation folder is uploaded to gdrive. We need it for destroying the cluster.
