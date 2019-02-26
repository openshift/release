Openshift-ansible templates for master/4.x
=========

openshift-ansible repo for 4.0 has been reworked, it now requires a bootstrap ignition file and
has different inventory and group vars.

The CI flow has been updated to include latest installer image, which is used to generate bootstrap
ignition file first.

## Template parameters
* `IMAGE_INSTALLER` - image with installer binaries, required to create bootstrap.ign file
* `IMAGE_ANSIBLE` - ansible repo image
* `IMAGE_TESTS` - image with openshift-tests
* `RPM_REPO_OPENSHIFT_ORIGIN` - repo with kubelet RPMs
* `CLUSTER_TYPE` - cluster platform - gcp, aws, openstack etc.
* `TEST_COMMAND` - specifies which tests should be executed
* `RELEASE_IMAGE_LATEST` - latest release bundle image, used by openshift-installer

## Containers
* `config` prepares config files in `IMAGE_INSTALLER` image:
  1. sets necessary env vars based on cluster type (libvirt install on GCP)
  2. runs `create install-config`
  3. modifies install configs to change a number of masters and workers created
  4. runs `create ignition-configs` to produce `boostrap.ign` in `/tmp/artifacts/installer`
  5. creates `/tmp/config-success` on success, otherwise - `/tmp/exit`

* `setup` runs ansible playbook in `IMAGE_ANSIBLE` image:
  1. waits for `/tmp/config-success` to appear
  2. runs `test/${CLUSTER_TYPE}/launch.yml` using `RPM_REPO_OPENSHIFT_ORIGIN` as an additional repo and bootstrap ignition path set to `/tmp/artifacts/installer/bootstrap.ign`
  3. the playbook would save admin's kubeconfig in `/tmp/artifacts/installer/auth/kubeconfig` on success
  4. creates `/tmp/setup-success` on success, otherwise - `/tmp/exit`

* `test` runs tests in `IMAGE_TESTS`:
  1. waits for `/tmp/setup-success` to be created
  2. uses `/tmp/artifacts/installer/auth/kubeconfig` to connect to the clsuter
  3. waits for ingress pods to appear
  4. sets env vars specific to the cluster type
  5. runs test suite using `TEST_SUITE` and `TEST_COMMAND` env vars
  6. creates `/tmp/shared/exit` when tests are finished

* `teardown` collects cluster artifacts and deprovisions the cluster in `IMAGE_ANSIBLE`
  1. waits until `/tmp/shared/exit` is created
  2. sets `KUBECONFIG=/tmp/artifacts/installer/auth/kubeconfig` and collects available info about the cluster - nodes, events, pods etc.
  3. runs `test/${CLUSTER_TYPE}/deprovision.yml` playbook once artifacts collection is done
