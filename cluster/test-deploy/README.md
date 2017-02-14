# Deploy OpenShift for e2e testing on GCE

Standard setup for an e2e test environment on GCE is provided in this directory. The data directory
should have:

* `gce.json` containing the GCE service account credentials to use that have permission to create instances, networks, and a bucket in project `openshift-gce-devel-ci`
* `ops-mirror.pem` containing the client certificate for the OpenShift ops mirror
* `ssh-privatekey` (optional) with the private key to use for the GCE instances
* `ssh-publickey` (optional) a key to use with the above private key

See `data/vars.yaml` for the default settings.  This depends on the `openshift/origin-gce:latest` image
which is a pre-built version of the GCE reference architecture and the openshift-ansible playbooks for the
appropriate release.

```
$ cd data

# launch cluster
$ INSTANCE_PREFIX=pr345 ../../bin/local.sh ansible-playbook \
    -e openshift_test_repo=https://storage.googleapis.com/origin-ci-test/pr-logs/12940/test_pull_requests_origin_gce/559/artifacts/rpms \
    playbooks/launch.yaml

# after cluster is launched, admin.kubeconfig is copied locally
$ KUBECONFIG=admin.kubeconfig oc status

# teardown cluster
$ INSTANCE_PREFIX=pr345 ../../bin/local.sh ansible-playbook playbooks/terminate.yaml

# get a shell in the ansible environment
$ INSTANCE_PREFIX=pr345 ../../bin/local.sh
```

The following ansible variables are commonly used:

* `openshift_test_repo` is the URL to a yum repo to use to install
* `openshift_image_tag` (optional) is the suffix of the image to run with
* `openshift_pkg_version` (optional) is the exact package value to use `-0.0.1` if installing RPMs that don't match the desired version

The following environment variables can be provided

* `INSTANCE_PREFIX` is a value that should be unique across all clusters running in the project. It is provided as an env var to allow inventory to be calculated by Ansible.
* `OPENSHIFT_ANSIBLE_IMAGE` (defaults to `openshift/origin-gce:latest`) the image to deploy from

