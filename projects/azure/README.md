# OSA CI

The current directory contains CI configuration for the OSA project, albeit it's not
exhaustive. The present document serves as documentation for anything CI-related to OSA.

OSA, from the Red Hat side, is comprised of a couple of different Github repos:

* [openshift/openshift-azure](https://github.com/openshift/openshift-azure/)
  This is the main code repository where all production code used by Microsoft
  is developed.
* [openshift/azure-misc](https://github.com/openshift/azure-misc/)
  This repo contains various tools used either in our CI or by SRE processes.
  (NOTE: This repository is private.)
* [openshift/azure-sop](https://github.com/openshift/azure-sop/)
  This repo contains various SOPs.
* [openshift/openshift-ansible](https://github.com/openshift/openshift-ansible/)
  The VM image build process is currently maintained in this repo.

In order to test and merge changes in these repositories, we use a couple of novel tools
in our CI. Namely:

* [ci-operator](https://github.com/openshift/ci-tools)

  This tool is responsible for running [jobs](#ci-operator-jobs) by using Openshift resources.
  There are a bunch of useful docs in the `ci-operator` repo, it is suggested to
  go through at least [ONBOARD.md](https://github.com/openshift/ci-tools/blob/master/ONBOARD.md), [ARCHITECTURE.md](https://github.com/openshift/ci-tools/blob/master/ARCHITECTURE.md), and [CONFIGURATION.md](https://github.com/openshift/ci-tools/blob/master/CONFIGURATION.md).
  You should ensure you familiarize yourself with `ci-operator`.

* [Prow](https://github.com/kubernetes/test-infra/blob/master/prow/getting_started_deploy.md)

  Prow is the CI system used in both Kubernetes and the Openshift Origin projects.
  It is responsible for every user interaction in Github, scheduling of tests, and
  reporting results. As an end user you shouldn't need to familiarize yourself with Prow.


## ci-operator jobs

There are three different places where we store `ci-operator` and Prow configuration:

1. `ci-operator/config/openshift/openshift-azure/`

  This is where the ci-operator config is stored and what is meant to be used
  by end users. Here we are specifying what commands we want to run in order to
  build and test our code, and optionally publish container images.

2. `ci-operator/jobs/openshift/openshift-azure/`

  In order to deploy the `ci-operator` config, we need to use prowjobs and this
  is where we configure those. Prowjobs fall under three categories:

  | Type        | Description               |
  | ----------- | ------------------------- |
  | presubmits  | Pull request jobs         |
  | postsubmits | Branch jobs               |
  | periodics   | Periodically-running jobs |

Similarly, you can find the CI configuration for `azure-misc` in `ci-operator/jobs/openshift/azure-misc/`
and `ci-operator/config/openshift/azure-misc/`.

All changes in `ci-operator/` are automatically applied in the CI cluster by Prow
right after a pull request is merged.

## How to work with CI

### How to merge a pull request

Every pull request in our repos needs to satisfy the following requirements:
* all [automated jobs](#automated-jobs) are passing
* your pull request has the following labels:
  - `lgtm`
  - `approved`

  `lgtm` stands for `looks good to me` and can be added by anyone who reviewed your pull
  request by commenting `/lgtm`.

  `approved` can only be added by owners of the repository by commenting either `/lgtm`
  or `/approve`. Approvers can be found in `OWNERS` files.

* your pull request does not have the following labels:
  - `do-not-merge/hold`
  - `do-not-merge/work-in-progress`
  - `needs-rebase`

  Anybody can `/hold` a pull request, signaling that it warrants more discussion.
  Removing the hold label can be removed with `/hold cancel`.

  You can signal that your pull request is a work in progress by adding a `WIP` prefix
  in your pull request title. The bot should automatically add or remove the label depending
  on whether the `WIP` prefix is found in your pull request title.

#### Update OWNERS files in openshift/release

All `OWNERS` files under the `ci-operator` directory are automatically updated
based on the `OWNERS` files found in the respective repositories. Use the following
script to update those files:

```console
$ ./ci-operator/populate-owners.sh
```

### Automated jobs

The following CI jobs run automatically on every PR in `openshift-azure`.

| Job              | Description                       |
| ---------------- | --------------------------------- |
| `ci/prow/unit`   | unit tests                        |
| `ci/prow/verify` | verification tests                |
| `ci/prow/images` | binary and container image builds |
| `ci/prow/e2e`    | e2e tests                         |

When a test fails in your PR and the test failure is unrelated to your changes, you need to
triage the failure, and compare it with the existing
set of [open issues tracking test failures](https://github.com/openshift/openshift-azure/issues?q=is%3Aissue+is%3Aopen+label%3Akind%2Ftest-flake).
If you don't find a match, you should open a new issue to track the new failure and comment
`/kind test-flake` in it in order for the github bot to label the issue appropriately.
Otherwise, link the existing issue in your PR. Then, you can `/retest` your PR.

For any infrastructure-related issues, make sure to contact the Developer Productivity
team who is responsible for managing the OpenShift CI Infrastructure at [#forum-testplatform](https://coreos.slack.com/).

Optionally, you can request specific long-running tests to run that are not
running in PRs by default.

| Command                    | Description                                                  |
| -------------------------- | ------------------------------------------------------------ |
| `/test scaleupdown`        | scale up followed by a scale down of the cluster             |
| `/test etcdbackuprecovery` | backup a cluster, mutate state, then restore from the backup |
| `/test keyrotation`        | rotate all the certificates in a cluster                     |

### Run a job manually

You should be able to run tests locally in `openshift-azure` by using the `make` targets
directly. In this document, we are going to explain how to simulate running these tests
similarly to how they run in CI. The point of using `ci-operator` is to minimize the
differences between using the CI system and running tests manually. To run a `ci-operator`
job manually, it is recommended to use the `ci-operator` container image.
```console
docker pull registry.svc.ci.openshift.org/ci/ci-operator:latest
```

`ci-operator` needs a kubeconfig in place in order to use a running cluster to run the tests.
Obtain the `oc login` command from the [OpenShift CI WebConsole](https://api.ci.openshift.org/console/)
and perform a login in your terminal. You should be able to access the CI cluster simply
by being a member of the [OpenShift Github organization](https://github.com/orgs/openshift/people).

Note: all further instructions assume you are currently in the root directory of this repository

Create a `secret` file for storing azure-related secrets using `cluster/test-deploy/azure/secret_example` as a template.

```sh
cp cluster/test-deploy/azure/secret_example cluster/test-deploy/azure/secret
# insert/update credentials in cluster/test-deploy/azure/secret
```

Set the location of the namespace you wish to use for the `ci-operator` jobs
```sh
export CI_OPERATOR_NAMESPACE=your-chosen-namespace
```

## Testing E2E-Upgrade script locally:

To test e2e-upgrade script we can emulate prow and ci-operator env with docker command:
```
docker run -it --privileged \
-v $GOPATH/src/github.com/openshift/release/cluster/test-deploy/azure:/usr/secrets \
-v $GOPATH/src/github.com/openshift/openshift-azure:/go/src/github.com/openshift/openshift-azure:Z \
registry.svc.ci.openshift.org/azure/test-base:latest bash
# prow release_tag resource_group
prow v0.0 test-cluster
# this will initiate a cluster from `tags/v0.0` tag and leave you to execute next steps manually. Example:
./hack/upgrade.sh $RESOURCEGROUP
make e2e

```
Note: limitations are that tests are done using LATEST container images, and you might need to build destination images manually
and set them using `export SYNC_IMAGE=registry/namespace/sync:latest` before calling upgrade.

to initiate source branch by executing `prow v0.0`. This will CD you yo local code base you are testing. From there you can execute `make update`

## CI secrets

We use various OpenShift secrets in our CI. You can manage these secrets in the
`azure` namespace in the CI cluster.

| Secret name                             | Description                                                                          |
| --------------------------------------- | ------------------------------------------------------------------------------------ |
| `cluster-secrets-azure`                 | contains all the necessary credentials for e2e and image build jobs                  |
| `cluster-secrets-azure-env`             | environment based secret. It can be injected to pod using pod spec (see azure-purge) |
| `openshift-on-azure-scratch-secret`     | quay robot secret used for mirroring images between the CI registry and quay         |


### cluster-secrets-azure

Today we use `cluster-secrets-azure` as a grab bag of all the different secrets we
need in place in order for the e2e and image build tests to work correctly. The OSA jobs are
using `Web API App` credentials on Azure to create clusters. If for some reason you need to
rotate the Azure credentials, follow this process:

1. Go to `Azure Active Directory` -> `App Registrations` -> `ci-operator-jobs` -> `Settings` -> `Keys`
2. Delete old key, and create new one.
3. Create a file named `secret` with the following format:

```sh
export AZURE_CLIENT_ID=<web app id>
export AZURE_CLIENT_SECRET=<new key>
export AZURE_TENANT_ID=<tenant id>
export AZURE_SUBSCRIPTION_ID=<subscription id>
```

4. Create or update the `cluster-secrets-azure` secret in the `azure` namespace.

You need to make sure you also have the rest of the credentials in place in order to create or
update `cluster-secrets-azure`

| Name                        | Description                                         |
| --------------------------- | --------------------------------------------------- |
| `secret`                    | Azure credentials                                   |
| `ssh-privatekey`            | SSH key (used by image builds - can be any SSH key) |
| `certs.yaml`                | Ops mirror certificates (used by image builds)      |
| `.dockerconfigjson`         | Geneva images pull secret                           |
| `system-docker-config.json` | Red Hat registry image pull secret                  |
| `logging-int.cert`          | Geneva logging certificate                          |
| `logging-int.key`           | Geneva logging key                                  |
| `metrics-int.cert`          | Geneva metrics certificate                          |
| `metrics-int.key`           | Geneva metrics key                                  |

TODO: In the future, split this into separate secrets so in case we need to rotate the CI credentials
we will not need to have the rest of the secrets in place.

```console
  oc create secret generic cluster-secrets-azure \
  --from-file=cluster/test-deploy/azure/secret \
  --from-file=cluster/test-deploy/azure/ssh-privatekey \
  --from-file=cluster/test-deploy/azure/certs.yaml \
  --from-file=cluster/test-deploy/azure/.dockerconfigjson \
  --from-file=cluster/test-deploy/azure/system-docker-config.json \
  --from-file=cluster/test-deploy/azure/logging-int.cert \
  --from-file=cluster/test-deploy/azure/logging-int.key \
  --from-file=cluster/test-deploy/azure/metrics-int.cert \
  --from-file=cluster/test-deploy/azure/metrics-int.key \
  -o yaml --dry-run | oc apply -n azure -f -
```

5. Ensure the secret is placed in the [ci-secret-mirroring-controller config](https://github.com/openshift/release/blob/master/core-services/secret-mirroring/_mapping.yaml). The controller will make sure to keep the secret in sync between the `azure` and the `ci` namespace where all CI tests run.



### cluster-secrets-azure-env

This secret is used by the azure-purge job to authenticate in Azure when garbage-collecting stale resources.

To rotate this secret:

```console
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
```

* _[`azure-purge`](./azure-purge)_ is responsible for cleaning up long-lived resource groups in our subscription (created either by our CI tests or for development purposes)
* _[`image-mirror-openshift-azure-v3.11-quay`](./image-mirror)_ mirrors images from the `azure` CI namespace to `quay.io/openshift-on-azure`, the latter being used by our customers and developers alike
* _[`secret-refresh`](./secret-refresh)_ refreshes all azure dev secrets each weekend


We need to check whether the above jobs are in a working state. Access to the cluster is granted
to every member of the openshift github organization. Access to the `azure` namespace is controlled
by the [`azure-team` group](./cluster-wide.yaml). If you need to update group membership, you need to
open a pull request adding your Github username in the group, and once your pull request is merged,
ask an existing member of the `azure-team` group to apply the changes on the cluster.

``
oc apply -f cluster-wide.yaml
``

In general, all changes in `projects/azure/` are not automatically applied in the CI cluster. CI admins can be contacted at [#forum-testplatform](https://coreos.slack.com/). After your
pull request is merged, apart from updating the group, you should be able to `oc apply` all other changes
in the `azure` namespace.

## Building container images

To onboard a new container image into CI and possibly setup mirroring of the image to quay the
following steps should be performed:

* Ensure there is a `Dockerfile.<image_name>` in [openshift-azure](https://github.com/openshift/openshift-azure)
specifying how to build the new image.
* Create 3 new make targets in that repository for the various stages leading up to building the image
  * one target for building the binary (`make <image_name>-bin`)
  * one target for building the container image (`make <image_name>-image`)
  * one target for pushing the container image to the public quay registry (`make <image_name>-push`)
* Add the target for building the binary to the `make all` chain
* Add the binary name to the `make clean` chain
* Add the binary to `.gitignore`
* Back in the release repo, [configure `ci-operator`](https://github.com/openshift/release/blob/5118144f5354ac4cb27c8ba7517f0c5e3715602c/ci-operator/config/openshift/openshift-azure/openshift-openshift-azure-master.yaml#L9-L49) to build the image by addding a new entry to the `images` key as follows:
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
* If the image needs to be mirrored from the CI registry to [our public quay account](https://quay.io/organization/openshift-on-azure/) then you need to update the
[image mirror config](https://github.com/openshift/release/blob/master/projects/azure/image-mirror/image-mirror.yaml)
in the release repo:
	* Add a new entry to the `items[0].data.openshift-azure_<openshift_version>_quay` key of that file which looks as follows:
	```yaml
	registry.svc.ci.openshift.org/azure/azure-plugins:<image_name> quay.io/openshift-on-azure/<image_name>:<openshift_version> quay.io/openshift-on-azure/<image_name>:latest
	```
	where: `<image_name>` is the name of the image and `<openshift_version>` is the currently supported openshift version e.g. `v3.11`
  * The image mirror job cannot create repos in quay, so an initial manual push of the new image using the make target is required (`make <image_name>-push`).
  * Once the image is pushed manually, you need to give write permissions to the `openshift-on-azure+openshiftci` robot account in quay.

The new image and others configured as such are built for [every commit pushed to master](https://github.com/openshift/release/blob/03d68b76db023721990dd24aeddd9a03d6a02bc3/ci-operator/jobs/openshift/openshift-azure/openshift-openshift-azure-master-postsubmits.yaml#L57-L86) and also on a [daily basis](https://github.com/openshift/release/blob/03d68b76db023721990dd24aeddd9a03d6a02bc3/ci-operator/jobs/openshift/openshift-azure/openshift-openshift-azure-periodics.yaml#L476-L505).

## Test dependencies

If you need to update the base image used by our tests, you should make changes to the [`test-base`](https://github.com/openshift/release/blob/master/projects/azure/base-images/test-base.yaml)
image build and once your PR is merged:
* apply the build config in the cluster:
```console
$ oc apply -f projects/azure/base-images/test-base.yaml
```
* trigger a build of your changes:
```console
$ oc start-build bc/test-base -n azure
```
