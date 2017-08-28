# Deploy OpenShift for e2e testing on GCE

Standard setup for an e2e test environment on GCE is provided in this directory. The data directory
should have:

* `gce.json` containing the GCE service account credentials to use that have permission to create instances, networks, and a bucket in project `openshift-gce-devel-ci`
* `ops-mirror.pem` containing the client certificate for the OpenShift ops mirror
* `ssh-privatekey` (optional) with the private key to use for the GCE instances
* `ssh-publickey` (optional) a key to use with the above private key

See `data/vars.yaml` for the default settings.  This depends on the `openshift/origin-gce:latest` image
which is a pre-built version of the GCE reference architecture and the openshift-ansible playbooks for the
appropriate release. That image is built from https://github.com/openshift/origin-gce.

Other prerequisites:

* Docker 1.12+ installed and available
* Your system time must be up to date in order for gcloud to
  authenticate to GCE (run `sudo ntpd -gq` in your VM if necessary)

```
# launch cluster using the latest RPMs
$ make WHAT=mycluster up

# after cluster is launched, admin.kubeconfig is copied locally
$ KUBECONFIG=admin.kubeconfig oc status

# teardown cluster
$ make WHAT=mycluster down

# get a shell in the ansible environment
$ make WHAT=mycluster sh
```

The following ansible variables are commonly used:

* `openshift_test_repo` is the URL to a yum repo to use to install
* `openshift_image_tag` (optional) is the suffix of the image to run with
* `openshift_pkg_version` (optional) is the exact package value to use `-0.0.1` if installing RPMs that don't match the desired version

The following environment variables can be provided

* `OPENSHIFT_ANSIBLE_IMAGE` (defaults to `openshift/origin-gce:latest`) the image to deploy from

