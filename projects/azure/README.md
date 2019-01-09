# Azure project

Azure project is a flavor of OpenShift dedicated hosted, on Microsoft Azure. This repository contains code for building release artifacts, testing, and life-cycle.
Main code repository is located in [Openshift Azure](https://github.com/openshift/openshift-azure/) project

# Test CI-operator jobs

CI-Operator jobs are being triggered using [prow](https://github.com/kubernetes/test-infra/tree/master/prow).
The Prow configuration is located in files within this repository at `ci-operator/jobs/openshift/openshift-azure/*.yaml`

To run a CI-Operator job manually it is recommended to use the [CI-Operator](https://github.com/openshift/ci-operator) container image
```
docker pull registry.svc.ci.openshift.org/ci/ci-operator:latest
```

The templates used to run all of our ci-operator jobs (vm image builds and e2e tests) are located in

```
ci-operator/templates/openshift/openshift-azure/
```

Obtain the `oc login` command from the OpenShift CI WebConsole and perform a login in your terminal

Note: all further instructions assume you are currently in the root directory of this repository

Create a `secret` file for storing azure-related secrets using `cluster/test-deploy/azure/secret_example` as a template.

```
cp cluster/test-deploy/azure/secret_example cluster/test-deploy/azure/secret
# insert/update credentials in cluster/test-deploy/azure/secret
```

Set the location of the namespace you wish to use for the ci-operator jobs
```
export CI_OPERATOR_NAMESPACE=your-chosen-namespace
```

#### Testing vm image builds

Generate a new ssh keypair making sure to set the name of the keypair file as `ssh-privatekey`

```
ssh-keygen -t rsa -b 4096 -f cluster/test-deploy/azure/ssh-privatekey 
```

Checkout the repository containing the yum client certificates required by openshift-ansible to update the packages on the root VM.
```
git clone git@github.com:openshift/aos-ansible.git ../aos-ansible
```

Create `cluster/test-deploy/azure/certs.yaml` with the following format making sure to replace the `<contents of *>` placeholders
```
yum_client_cert_contents: |
	<contents of ../aos-ansible/playbooks/roles/ops_mirror_bootstrap/files/client-cert.pem>

yum_client_key_contents: |
	<contents of ../aos-ansible/playbooks/roles/ops_mirror_bootstrap/files/client-key.pem>
```

Example: Build a rhel base vm image
```
docker run \
--rm \
-it \
--env DEPLOY_OS=rhel7 \
--volume $HOME/.kube/config:/root/.kube/config \
--volume $(pwd):/release \
registry.svc.ci.openshift.org/ci/ci-operator:latest \
--config /release/ci-operator/config/openshift/openshift-azure/openshift-openshift-azure-master.yaml \
--git-ref=openshift/openshift-azure@master \
--namespace=${CI_OPERATOR_NAMESPACE} \
--template /release/ci-operator/templates/openshift/openshift-azure/build-base-image.yaml \
--secret-dir /release/cluster/test-deploy/azure/ \
--target build-base-image
```

Example: Build a centos base vm image
```
docker run \
--rm \
-it \
--env DEPLOY_OS=centos7 \
--volume $HOME/.kube/config:/root/.kube/config \
--volume $(pwd):/release \
registry.svc.ci.openshift.org/ci/ci-operator:latest \
--config /release/ci-operator/config/openshift/openshift-ansible/openshift-openshift-ansible-release-3.11.yaml \
--git-ref=openshift/openshift-azure@master \
--namespace=${CI_OPERATOR_NAMESPACE} \
--template /release/ci-operator/templates/openshift/openshift-azure/build-base-image.yaml \
--secret-dir /release/cluster/test-deploy/azure/ \
--target build-base-image
```

Example: Build a rhel node vm image with openshift 3.11
```
docker run \
--rm \
-it \
--env DEPLOY_OS=rhel7 \
--env OPENSHIFT_RELEASE="3.11" \
--volume $HOME/.kube/config:/root/.kube/config \
--volume $(pwd):/release \
registry.svc.ci.openshift.org/ci/ci-operator:latest \
--config /release/ci-operator/config/openshift/openshift-ansible/openshift-openshift-ansible-release-3.11.yaml \
--git-ref=openshift/openshift-azure@master \
--namespace=${CI_OPERATOR_NAMESPACE} \
--template /release/ci-operator/templates/openshift/openshift-azure/build-node-image.yaml \
--secret-dir /release/cluster/test-deploy/azure/ \
--target build-node-image
```

Example: Build a centos node vm image with openshift 3.11
```
docker run \
--rm \
-it \
--env DEPLOY_OS=centos7 \
--env OPENSHIFT_RELEASE="3.11" \
--volume $HOME/.kube/config:/root/.kube/config \
--volume $(pwd):/release \
registry.svc.ci.openshift.org/ci/ci-operator:latest \
--config /release/ci-operator/config/openshift/openshift-ansible/openshift-openshift-ansible-release-3.11.yaml \
--git-ref=openshift/openshift-azure@master \
--namespace=${CI_OPERATOR_NAMESPACE} \
--template /release/ci-operator/templates/openshift/openshift-azure/build-node-image.yaml \
--secret-dir /release/cluster/test-deploy/azure/ \
--target build-node-image
```

#### Running e2e tests

Example: Run e2e tests
```
docker run \
--rm \
-it \
--volume $HOME/.kube/config:/root/.kube/config \
--volume $(pwd):/release \
registry.svc.ci.openshift.org/ci/ci-operator:latest \
--config /release/ci-operator/config/openshift/openshift-azure/openshift-openshift-azure-master.yaml \
--git-ref=openshift/openshift-azure@master \
--namespace=${CI_OPERATOR_NAMESPACE} \
--template /release/ci-operator/templates/openshift/openshift-azure/cluster-launch-e2e-azure.yaml \
--secret-dir /release/cluster/test-deploy/azure/
```

Example: Run an upgrade and then perform e2e tests
```
docker run \
--rm \
-it \
--volume $HOME/.kube/config:/root/.kube/config \
--volume $(pwd):/release \
registry.svc.ci.openshift.org/ci/ci-operator:latest \
--config /release/ci-operator/config/openshift/openshift-azure/openshift-openshift-azure-master.yaml \
--git-ref=openshift/openshift-azure@master \
--namespace=${CI_OPERATOR_NAMESPACE} \
--template /release/ci-operator/templates/openshift/openshift-azure/cluster-launch-e2e-azure-upgrade.yaml \
--secret-dir /release/cluster/test-deploy/azure/
```

Example: Run origin conformance tests
```
docker run \
--rm \
-it \
--env TEST_COMMAND="TEST_FOCUS=Suite:openshift/conformance/parallel run-tests" \
--env TEST_IMAGE="registry.svc.ci.openshift.org/openshift/origin-v3.11:tests" \
--volume $HOME/.kube/config:/root/.kube/config \
--volume $(pwd):/release \
registry.svc.ci.openshift.org/ci/ci-operator:latest \
--config /release/ci-operator/config/openshift/openshift-azure/openshift-openshift-azure-master.yaml \
--git-ref=openshift/openshift-azure@master \
--namespace=${CI_OPERATOR_NAMESPACE} \
--template /release/ci-operator/templates/openshift/openshift-azure/cluster-launch-e2e-azure.yaml \
--secret-dir /release/cluster/test-deploy/azure/
```

#### Cleanup

Delete the `aos-ansible` repository if desired
```
rm -rf ../aos-ansible
```


# Secrets

We use 2 types of secrets. Both of them contain the same data but in a different formats.

```
cluster-secrets-azure: file based secret. It can be sourced by script (see ci-operator jobs)
cluster-secrets-azure-env: environment based secret. It can be injected to pod using pod spec (see azure-purge)
```

## cluster-secrets-azure

OSA jobs are using `Web API App` credentials on Azure to run jobs. If for some reason you need to rotate secret, follow this process:

1. Go to `Azure Active Directory` -> `App Registrations` -> `ci-operator-jobs` -> `Settings` -> `Keys`
2. Delete old key, and create new one.
3. Create secret example file:

```
export AZURE_CLIENT_ID=<web app id>
export AZURE_CLIENT_SECRET=<new key>
export AZURE_TENANT_ID=<tenant id>
export AZURE_SUBSCRIPTION_ID=<subscription id>
```

4. Create or udate the `cluster-secrets-azure` secret in the `azure` namespace.

You need to make sure you also have the required certificates in place in order to allow our
build VM process to download the OpenShift RPMs from the ops mirror. There are also the Geneva
secrets (image pull secret, logging, and metrics certificates).

TODO: In the future, split this into separate secrets so in case we need to rotate the CI credentials
we will not need to have the rest of the secrets in place.

```
  oc create secret generic cluster-secrets-azure \
  --from-file=cluster/test-deploy/azure/secret \
  --from-file=cluster/test-deploy/azure/ssh-privatekey \
  --from-file=cluster/test-deploy/azure/certs.yaml \
  --from-file=cluster/test-deploy/azure/.dockerconfigjson \
  --from-file=cluster/test-deploy/azure/logging-int.cert \
  --from-file=cluster/test-deploy/azure/logging-int.key \
  --from-file=cluster/test-deploy/azure/metrics-int.cert \
  --from-file=cluster/test-deploy/azure/metrics-int.key \
  -o yaml --dry-run | oc apply -n ci -f -
```

5. Ensure the secret is placed in the [ci-secret-mirroring-controller config](https://github.com/openshift/release/blob/master/cluster/ci/config/secret-mirroring/mapping.yaml). The controller will make sure to keep the secret in sync between the `azure` and the `ci` namespace where all CI tests run.



## cluster-secrets-azure-env

This secret is used by the azure-purge job to authenticate in Azure when garbage-collecting stale resources.

To rotate this secret:

```
source ./cluster/test-deploy/azure/secret
oc create secret generic cluster-secrets-azure-env --from-literal=azure_client_id=${AZURE_CLIENT_ID} --from-literal=azure_client_secret=${AZURE_CLIENT_SECRET} --from-literal=azure_tenant_id=${AZURE_TENANT_ID} --from-literal=azure_subscription_id=${AZURE_SUBSCRIPTION_ID} -o yaml --dry-run | oc apply -n azure -f -
```

## Other cron jobs

Apart from the ci-operator jobs, we run some cron jobs in the CI cluster for various tasks.
```console
$ oc get cj -n azure
NAME                                      SCHEDULE    SUSPEND   ACTIVE    LAST SCHEDULE   AGE
azure-purge                               0 * * * *   False     0         56m             45d
image-mirror-openshift-azure-v3.11-quay   0 * * * *   False     0         56m             21d
token-refresh                             0 0 * * *   False     1         44d             45d
```

* _azure-purge_ is responsible for cleaning up long-lived resource groups in our subscription (created either by our CI tests or for development purposes)
* _image-mirror-openshift-azure-v3.11-quay_ mirrors images from the azure namespace to quay.io/openshift-on-azure that both MSFT uses for running the sync pod in customer clusters and SRE tooling we use in our SRE cluster
* _token-refresh_ refreshes a token from the AWS registry that we put inside node images built from Origin master to pull images for the cluster

We need to check whether the above jobs are in a working state. Access to the cluster is granted to every member of the openshift github organization. Access to the azure namespace is controlled by the [azure-team group](./cluster-wide.yaml).

# Building container images

To onboard a new container image into CI and possibly setup mirroring of the image to quay the following steps should be 
performed:

* Ensure there is a `Dockerfile.<image_name>` in the [openshift on azure repo](https://github.com/openshift/openshift-azure) 
specifying how to build the new image
* Create 3 new make targets in that repository for the various stages leading up to building the image
  * one target for building the binary
  * one target for building the container image
  * one target for pushing the container image to the public quay registry
* Add the target for building the binary to the `make all` chain
* Add the binary name to the `make clean` chain
* Add the binary to `.gitignore`
* Back in the [openshift release repo](https://github.com/openshift/release) add the image specs to the 
[ci-operator](https://github.com/openshift/release/blob/master/ci-operator/config/openshift/openshift-azure/openshift-openshift-azure-master.yaml) 
config to onboard building the image in CI 
  * Add a new entry to the `images` key of that file which looks as follows:
  	```yaml
	- dockerfile_path: Dockerfile.<image_name>
      from: base
      inputs:
        bin:
          paths:
          - destination_dir: .
            source_path: /go/src/github.com/openshift/openshift-azure/<image_source>
      to: <image_name>
	```
* If you intend for the image to be mirrored from the CI registry to the public quay registry then you need to update the
[image mirror config](https://github.com/openshift/release/blob/master/projects/azure/image-mirror/image-mirror.yaml) 
in the release repo
	* Add a new entry to the `items[0].data.openshift-azure_<openshift_version>_quay` key of that file which looks as follows:
	```yaml
	registry.svc.ci.openshift.org/azure/azure-plugins:<image_name> quay.io/openshift-on-azure/<image_name>:<openshift_version> quay.io/openshift-on-azure/<image_name>:latest
	```
	where:
	* `<image_name>` is the name of the image
	* `<openshift_version>` is the currently supported openshift version e.g. v3.11
* Note: The new image and others configured as such are built for [every commit pushed to master](https://github.com/openshift/release/blob/03d68b76db023721990dd24aeddd9a03d6a02bc3/ci-operator/jobs/openshift/openshift-azure/openshift-openshift-azure-master-postsubmits.yaml#L57-L86) 
and also on a 
[daily basis](https://github.com/openshift/release/blob/03d68b76db023721990dd24aeddd9a03d6a02bc3/ci-operator/jobs/openshift/openshift-azure/openshift-openshift-azure-periodics.yaml#L476-L505).
* Note: Since the image mirror job is unable to create repos in quay, an initial manual push of the new image using the 
make target is required.
* Note: In contrast, the [test-base](https://github.com/openshift/release/blob/master/projects/azure/base-images/test-base.yaml) 
image build is not currently a prow job but only an OpenShift build at the moment. Changes to the `test-base` config
therefore requires the build to be re-triggered manually via the CI cluster UI or using the oc CLI. For example:
```yaml
oc start-build bc/test-base -n azure
```
