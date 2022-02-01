# Cluster build05

[build05](https://console-openshift-console.apps.build05.gcp.ci.openshift.org) is an OpenShift-cluster managed by DPTP-team. It is one of the clusters for running Prow job pods.

The secrets have been uploaded to BitWarden items.

* the key file for the service account `ocp-cluster-installer`: BitWarden item `build_farm_build02`.
* the SSH key pair (`id_rsa` and `id_rsa.pub`): BitWarden item `build_farm_build02`.
* The auth info for `kubeadmin` and the cert-based kubeconfig file (attachment `b05.admin.cert.kubeconfig`): BitWarden item `build_farm_build05`. (TODO: hongkliu)

## Installation

### GCP Project
The gcp project `openshift-ci-build-farm` for installation of this cluster: [gcp console](https://console.cloud.google.com/home/dashboard?project=openshift-ci-build-farm). The project is created by [DPP team](hhttps://issues.redhat.com/browse/DPP-4926).

### Base domain, Service account and Public Key
We reused the public zone "gcp.ci.openshift.org" for [build02](../02_cluster) which is the base domain for installer, and the service account `ocp-cluster-installer`.

Download the attachment "openshift-ci-build-farm-64e4ce412ae3.json" and `id_rsa.pub` of BW item `build_farm_build02`.

### Region

`build02` and `build04`: `us-east1`.

`build05`: `us-west1`.

### Machine type


|         | master                   | worker                   |
|---------|--------------------------|--------------------------|
| build02 | n1-standard-32 150G SSD persistent disk | n1-standard-16 600G SSD persistent disk |
| build04 | custom-16-65536 128G SSD persistent disk | custom-16-65536 128G SSD persistent disk |
| build05 | n1-standard-32 300G SSD persistent disk | n1-standard-16 600G SSD persistent disk |


### Pull Secret


```console
$ oc --context build01 extract -n openshift-config secret/pull-secret --to=-
```

### OCP Version:


https://amd64.ocp.releases.ci.openshift.org/releasestream/4-stable/release/4.9.18

[4.9.18](https://amd64.ocp.releases.ci.openshift.org/releasestream/4-stable/release/4.9.18): The latest stable as now.

```console
$ wget https://openshift-release-artifacts.apps.ci.l2s4.p1.openshiftapps.com/4.9.18/openshift-install-mac-4.9.18.tar.gz
$ tar -xzvf openshift-install-mac-4.9.18.tar.gz
$ ./openshift-install version
./openshift-install 4.9.18
built from commit eb132dae953888e736c382f1176c799c0e1aa49e
release image registry.ci.openshift.org/ocp/release@sha256:b9ede044950f73730f00415a6fe8eb1b5afac34def872292fd0f9392c9b483f1
release architecture amd64
```


### Generate `install-config.yaml`


```
./openshift-install create install-config
? SSH Public Key /Users/hongkliu/.ssh/id_rsa_build02.pub
? Platform gcp
? Service Account (absolute path to file or JSON content) [Enter 2 empty lines to finish]/Users/hongkliu/Downloads/build05.install/openshift-ci-build-farm-64e4ce412ae3.json


? Service Account (absolute path to file or JSON content)
/Users/hongkliu/Downloads/build05.install/openshift-ci-build-farm-64e4ce412ae3.json
INFO Saving the credentials to "/Users/hongkliu/.gcp/osServiceAccount.json"
? Project ID OpenShift CI Build Infra (openshift-ci-build-farm)
? Region us-west1
INFO Credentials loaded from file "/Users/hongkliu/.gcp/osServiceAccount.json"
? Base Domain gcp.ci.openshift.org
? Cluster Name build05
? Pull Secret
```

Modify [the machine type and disk size for master and worker](https://docs.openshift.com/container-platform/4.9/installing/installing_gcp/installing-gcp-customizations.html#installation-configuration-parameters-additional-gcp_installing-gcp-customizations):

```console
...
  name: worker
  platform:
    gcp:
      type: n1-standard-16
      osDisk:
        diskSizeGB: 600
        type: pd-ssd
...
  name: master
  platform:
    gcp:
      type: n1-standard-32
      osDisk:
        diskSizeGB: 300
        type: pd-ssd
```


### Create the cluster

> ./openshift-install create  cluster --log-level=debug

TODO: Upload the installation folder to gdrive


