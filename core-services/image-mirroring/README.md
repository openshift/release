# Mirroring images to external repositories

Images built and promoted by Prow/ci-operator jobs are only kept inside the CI
cluster registry. To publish them, they need to be mirrored to an external
repository, like Quay. This is achieved by periodic Prow jobs. These jobs
consume image mappings from the subdirectories of this directory. These image
mapping files determine what should be mirrored where and are usually separated
by version.

## Configuring mirroring for new images

Simply submit a PR adding the image to then appropriate mapping file. You will
need an approval of an owner of the image set. The following external repositories
are currently targeted by existing mirroring jobs:

 - [codeready-toolchain](./codeready-toolchain/): `quay.io/codeready-toolchain`
 - [knative](./knative/): `quay.io/openshift-knative`
 - [kubefed](./kubefed/): `quay.io/openshift/kubefed-*`
 - [openshift](./openshift/): `quay.io/openshift`
 - [tekton](./tekton/): `quay.io/openshift-pipeline`
 - [toolchain](./toolchain/): `quay.io/openshiftio`
 - [ocs-operator](./ocs-operator): `quay.io/ocs-dev`

## Configuring mirroring for new sets of images

Submit a PR adding a new subdirectory here, with at least a single mapping file
and an `OWNERS` file (so that you can maintain your mappings). The mapping files
should follow the `mapping_$name$anything` naming convention to avoid conflicts
when put to a ConfigMap.

Additionally, you will need to add a new Periodic job
[here](../../ci-operator/jobs/infra-image-mirroring.yaml).  You should not need
to modify anything in the job besides the items marked as `FIXME`, where you
just need to fill in the name of your image set (it should be the same as the
name of the subdirectory here). To push images to an external repository, the
job needs credentials. These credentials need to be available in the cluster as
a secret. The secrets are stored in DPTP Bitwarden vault and then synced to the
cluster: [talk to DPTP on Slack](https://coreos.slack.com/messages/CBN38N3MW)
about storing the credentials in Bitwarden.

### For DPTP: How to create new push credential secrets

See [SECRETS.md](../../ci-operator/SECRETS.md#push-credentials-for-image-mirroring-jobs).
