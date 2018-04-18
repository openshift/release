# Deploy OpenShift for e2e testing

Standard setup for an e2e test environment on supported clusters is provided in this directory. Subdirectories contain the default profiles. The deployment uses the `openshift/origin-ansible:latest` image to launch clusters.

Prerequisites:

* Docker 1.12+ installed and available on your local machine
* Your system time must be up to date in order for gcloud to authenticate to GCE (run `sudo ntpd -gq` in your VM if necessary)


## Profiles

* `gcp-dev` (default) - 1 master, 3 node cluster with bootstrapping (uses the `openshift-gce-devel` project, suitable for developers)
* `gcp` - 1 master, 3 node cluster with bootstrapping (uses the `openshift-gce-devel-ci` project, suitable for CI)
* `gcp-ha` - 3 master, 3 node cluster with bootstrapping (uses the `openshift-gce-devel-ci` project, suitable for CI)

In each profile, see `vars-origin.yaml` for the default settings (which is common across all profiles) and `vars.yaml` for the variables that differ.

### Configure a profile manually

Add the following files to the profile directory:

* `gce.json` containing the GCP service account credentials to use that have permission to create instances, networks, and a bucket in the project used by the profile
* `ops-mirror.pem` containing the client certificate for the OpenShift ops mirror
* `ssh-privatekey` (optional) with the private key to use for the GCP instances
* `ssh-publickey` (optional) a key to use with the above private key

### Configure a profile using shared secrets

Clone the shared secrets repo to `$SHARED_SECRETS`:

```shell
git clone git@github.com:openshift/shared-secrets.git
```

Copy secrets to a given `$PROFILE` in the in the release tools directory:

```shell
cp $SHARED_SECRETS/gce/aos-serviceaccount.json $RELEASE_TOOLS/$PROFILE/gce.json
cp $SHARED_SECRETS/gce/cloud-user@gce.pem $RELEASE_TOOLS/$PROFILE/ssh-privatekey
cp $SHARED_SECRETS/mirror/client.p12 $RELEASE_TOOLS/$PROFILE/ops-mirror.pem
```

## Usage

Set `WHAT` below to a name that will identify your cluster (it gets the domain `$WHAT.origin-gce.dev.openshift.com`).  Please include your LDAP username to avoid collisions with others.

You can set an alternate profile by passing `PROFILE=gcp` on the `make` arguments.

```
# launch cluster using the latest RPMs
$ make WHAT=mycluster up

# after cluster is launched, admin.kubeconfig is copied locally
$ KUBECONFIG=gcp-dev/admin.kubeconfig oc status

# teardown cluster
$ make WHAT=mycluster down

# get a shell in the ansible environment
$ make WHAT=mycluster sh

# launch a different profile
$ make WHAT=mycluster PROFILE=gcp-ha
```

## Advanced configuration

The following ansible variables are commonly used:

* `openshift_test_repo` is the URL to a yum repo to use to install
* `openshift_image_tag` (optional) is the suffix of the image to run with
* `openshift_pkg_version` (optional) is the exact package value to use `-0.0.1` if installing RPMs that don't match the desired version

The following environment variables can be provided

* `OPENSHIFT_ANSIBLE_IMAGE` (defaults to `openshift/origin-ansible:latest`) the image to deploy from

## Pushing images to the cluster registry

1. Add the cluster's registry (e.g. `docker-registry-default.apps.$WHAT.origin-gce.dev.openshift.com`) to the local Docker daemon's insecure registry list.

1. Log in to the cluster's registry using an SA from the namespace which should receive the image:

    ```shell
    oc sa get-token -n openshift builder | docker login -u builder --password-stdin docker-registry-default.apps.$WHAT.origin-gce.dev.openshift.com
    ```

1. Tag an image pointing at the cluster registry in the desired namespace:

    ```shell
    docker tag github.com/openshift/origin:b42d282 docker-registry-default.apps.$WHAT.origin-gce.dev.openshift.com/openshift/origin:b42d282
    ```

1. Push an image to the cluster registry:

    ```shell
    docker push docker-registry-default.apps.$WHAT.origin-gce.dev.openshift.com/openshift/origin:b42d282
    ```
