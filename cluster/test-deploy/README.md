# Deploy OpenShift for e2e testing

Standard setup for an e2e test environment on supported clusters is provided in this directory. Subdirectories contain the default configurations. The deployment uses the `openshift/origin-ansible:latest` image to launch clusters.

Configurations:

* `gcp` - 1 master, 3 node cluster with bootstrapping
* `gcp-ha` - 3 master, 3 node cluster with bootstrapping

For GCP, the data directory should have:

* `gce.json` containing the GCP service account credentials to use that have permission to create instances, networks, and a bucket in project `openshift-gce-devel-ci`
  * If you don't have access to credentials that create into this project, you can change the vars-origin.yaml file to set a different project. Recommended if you are not a CI bot.
* `ops-mirror.pem` containing the client certificate for the OpenShift ops mirror
* `ssh-privatekey` (optional) with the private key to use for the GCP instances
* `ssh-publickey` (optional) a key to use with the above private key

See `gcp/vars-origin.yaml` for the default settings (which is common across all GCP setups) and `gcp/vars.yaml` and `gcp-ha/vars.yaml` for the variables that differ.

Other prerequisites:

* Docker 1.12+ installed and available on your local machine
* Your system time must be up to date in order for gcloud to authenticate to GCE (run `sudo ntpd -gq` in your VM if necessary)

The default cluster type is `gcp`. You can set an alternate configuration by passing `TYPE=gcp-ha` on the `make` arguments.

```
# launch cluster using the latest RPMs
$ make WHAT=mycluster up

# after cluster is launched, admin.kubeconfig is copied locally
$ KUBECONFIG=admin.kubeconfig oc status

# teardown cluster
$ make WHAT=mycluster down

# get a shell in the ansible environment
$ make WHAT=mycluster sh

# launch a different profile
$ make WHAT=mycluster TYPE=gcp-ha
```

The following ansible variables are commonly used:

* `openshift_test_repo` is the URL to a yum repo to use to install
* `openshift_image_tag` (optional) is the suffix of the image to run with
* `openshift_pkg_version` (optional) is the exact package value to use `-0.0.1` if installing RPMs that don't match the desired version

The following environment variables can be provided

* `OPENSHIFT_ANSIBLE_IMAGE` (defaults to `openshift/origin-ansible:latest`) the image to deploy from

