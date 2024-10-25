# Deploy OpenShift for e2e testing

Standard setup for an e2e test environment on supported clusters is provided in this directory. Subdirectories contain the default profiles. The deployment uses the `openshift/origin-ansible:latest` image to launch clusters.

Prerequisites:

* Docker 1.12+ installed and available on your local machine
* Your system time must be up to date in order for gcloud to authenticate to GCE (run `sudo ntpd -gq` in your VM if necessary)


## Profiles

* `gcp-dev` (default) - 1 master, 3 node cluster with bootstrapping (uses the `openshift-gce-devel` project, suitable for developers)
* `gcp` - 1 master, 3 node cluster with bootstrapping (uses the `openshift-gce-devel-ci` project, suitable for CI)

In each profile, see `vars-origin.yaml` for the default settings (which is common across all profiles) and `vars.yaml` for the variables that differ.

### Configure a profile

This is the typical workflow to configure the development profile `gcp-dev` (but would apply to any other profile).

Clone the shared secrets repo to `$SHARED_SECRETS`:

```shell
git clone git@github.com:openshift/shared-secrets.git $SHARED_SECRETS
```

Copy secrets to their well-known locations in the profile directory:

```shell
cp $SHARED_SECRETS/gce/aos-serviceaccount.json $RELEASE_TOOLS/gcp-dev/gce.json

cp $SHARED_SECRETS/gce/cloud-user@gce.pem $RELEASE_TOOLS/gcp-dev/ssh-privatekey

cp $SHARED_SECRETS/mirror/ops-mirror.pem $RELEASE_TOOLS/gcp-dev/ops-mirror.pem
```

### Configure installer variables

**Add new installer variables** to a file such as `gcp-dev/zz_vars.yaml` (any YAML file in the profile directory will be treated as a variables file, and for now, the `zz_` prefix ensures that your variables will override any predefined ones). Keep in mind that the precedence order of the variable files in the profile is unspecified: to override variables in `vars.yaml` or `vars-origin.yaml` just modify those files directly for now.

## Usage

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
$ make WHAT=mycluster PROFILE=gcp
```

## Advanced configuration

The following ansible variables are commonly used:

* `openshift_test_repo` is the URL to a yum repo to use to install
* `openshift_image_tag` (optional) is the suffix of the image to run with
* `openshift_pkg_version` (optional) is the exact package value to use `-0.0.1` if installing RPMs that don't match the desired version

The following environment variables can be provided:

* `OPENSHIFT_ANSIBLE_IMAGE` (defaults to `openshift/origin-ansible:latest`) the image to deploy from

The following files can be added to a profile:

* `gce.json` containing the GCP service account credentials to use that have permission to create instances, networks, and a bucket in the project used by the profile
* `ops-mirror.pem` containing the client certificate for the OpenShift ops mirror
* `ssh-privatekey` (optional) with the private key to use for the GCP instances
* `ssh-privatekey.pub` (optional) a key to use with the above private key


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
