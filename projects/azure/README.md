# OSA CI

The current directory contains CI configuration for the OSA project. The present document
serves as documentation for anything CI-related to OSA.

OSA, from the Red Hat side, is comprised of a couple of different Github repos:
* [openshift/openshift-azure](https://github.com/openshift/openshift-azure/)
  This is the main code repository where all production code used by Microsoft
  is developed.
* [openshift/azure-misc](https://github.com/openshift/azure-misc/)
  This repo contains various tools used either in our CI or by SRE processes.
* [openshift/openshift-ansible](https://github.com/openshift/openshift-ansible/)
  The VM image build process is currently maintained in this repo.

In order to test and merge changes in these repositories, we use a couple of novel tools
in our CI. Namely:
* [ci-operator](https://github.com/openshift/ci-operator)
  This tool is responsible for running [jobs](#ci-operator-jobs) by using Openshift resources.
  There are a bunch of useful docs in the ci-operator repo, it is suggested to
  go through at least [ONBOARD.md](https://github.com/openshift/ci-operator/blob/master/ONBOARD.md), [ARCHITECTURE.md](https://github.com/openshift/ci-operator/blob/master/ARCHITECTURE.md), and [CONFIGURATION.md](https://github.com/openshift/ci-operator/blob/master/CONFIGURATION.md).
  You should ensure you familiarize yourself with `ci-operator`.
* [Prow](https://github.com/kubernetes/test-infra/blob/master/prow/README.md)
  Prow is the CI system used in both Kubernetes and the Openshift Origin projects.
  It is responsible for every user interaction in Github, scheduling of tests, and
  reporting results. As an end user you shouldn't need to familiarize yourself with Prow.


## ci-operator jobs

There are three different places where we store ci-operator and Prow configuration:

1. `ci-operator/config/openshift/openshift-azure/`
  This is where the ci-operator config is stored and what is meant to be used
  by end users. Here we are specifying what commands we want to run in order to
  build and test our code, and optionally publish container images.
2. `ci-operator/jobs/openshift/openshift-azure/`
  In order to deploy the `ci-operator` config, we need to use prowjobs and this
  is where we configure those. Prowjobs fall under three categories:
  * presubmits: These jobs run in PRs
  * postsubmits: These jobs run in merged commits
  * periodics: These jobs run periodically
3. `ci-operator/templates/openshift/openshift-azure`
  Unfortunately, we cannot define all types of tests in `ci-operator/config/openshift/openshift-azure/`.
  Hence, we use Openshift templates to do black-box testing with ci-operator.
  This directory contains the templates used by our e2e tests and by our image
  build processes. In order to learn more about writting tests using templates
  refer to [TEMPLATES.md](https://github.com/openshift/ci-operator/blob/master/TEMPLATES.md)

Similarly, you can find the CI configuration for `azure-misc` in `ci-operator/jobs/openshift/azure-misc/`
and `ci-operator/config/openshift/azure-misc/`.

## How to work with CI

### Automated jobs

The following CI jobs run automatically on every PR in `openshift-azure`.

| Job | Description |
| --- | --- |
| `ci/prow/unit` | runs unit tests |
| `ci/prow/verify` | runs verification tests |
| `ci/prow/images` | builds all binaries and images |
| `ci/prow/e2e` | runs e2e tests |

When a test fails in your PR, you need to triage the failure, and compare it with the existing
set of [open issues tracking test failures](https://github.com/openshift/openshift-azure/issues?q=is%3Aissue+is%3Aopen+label%3Akind%2Ftest-flake).
If you don't find a match, you should open a new issue to track the failure and comment
`/kind test-flake` in it in order for the github bot to label the issue appropriately.
Then, you can `/retest` your PR.

Optionally, you can request specific long-running tests to run that are not
running in PRs by default.

| Command | Description |
| --- | --- |
| `/test scaleupdown` | runs a test doing a scale up followed by a scale down of the cluster |
| `/test etcdrebackupcovery` | runs a test that backups a cluster, mutates state, then restores from the backup |
| `/test keyrotation` | runs a test that rotates all the certificates in a cluster |
| `/test prod` | runs a test using the production OSA RP |
| `/test vnet` | runs a custom vnet test using the production OSA RP |

Note that the tests using the production RP are not any useful to run in PRs unless
you update the tests themselves.

### Run a job manually

The point of using `ci-operator` is to minimize the differences between using the CI
system and running tests manually. To run a ci-operator job manually it is recommended
to use the [CI-Operator](https://github.com/openshift/ci-operator) container image.
```
docker pull registry.svc.ci.openshift.org/ci/ci-operator:latest
```

`ci-operator` needs a kubeconfig in place in order to use a running cluster to run the tests.
Obtain the `oc login` command from the [OpenShift CI WebConsole](https://api.ci.openshift.org/console/) and perform a login in your terminal.

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

#### Running e2e tests

For the e2e tests you will also need to have the Geneva secrets in place.
```
$ ls cluster/test-deploy/azure/
logging-int.cert  logging-int.key  metrics-int.cert  metrics-int.key  secret  secret_example vars.yaml
```

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


## CI secrets

We use 2 types of secrets. Both of them contain the same data but in a different formats.

```
cluster-secrets-azure: file based secret. It can be sourced by script (see ci-operator jobs)
cluster-secrets-azure-env: environment based secret. It can be injected to pod using pod spec (see azure-purge)
```

### cluster-secrets-azure

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
  -o yaml --dry-run | oc apply -n azure -f -
```

5. Ensure the secret is placed in the [ci-secret-mirroring-controller config](https://github.com/openshift/release/blob/master/cluster/ci/config/secret-mirroring/mapping.yaml). The controller will make sure to keep the secret in sync between the `azure` and the `ci` namespace where all CI tests run.



### cluster-secrets-azure-env

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

## Building container images

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
