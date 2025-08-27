Sanitize Prow Jobs
==================

This folder contains configuration that is required for [ci-tools/sanitize-prow-jobs](https://github.com/openshift/ci-tools/tree/main/cmd/sanitize-prow-jobs).

Useful Documentation
--------------------

- [Selecting an specific cluster](https://docs.ci.openshift.org/docs/how-tos/multi-architecture/#cluster-selection)
- [Configuring capabilities for a job](https://docs.ci.openshift.org/docs/how-tos/capabilities/)
- [Dynamic scheduling of Prowjobs](https://docs.ci.openshift.org/docs/internals/dynamic-scheduling/)

clusters.yaml
-------------

The file `_clusters.yaml` define the available build clusters, it contains information such as name, capacity, capabilities, etc.

```yaml
aws:
  - name: openshift-aws
    blocked: false
    capabilities:
    - arm64
    - gpu
    - build-tmpfs
    - highperf
    - rce
    - sshd-bastion
    - intranet
gcp:
  - name: openshift-gcp
    capabilities:
    - kvm
    capacity: 50
    blocked: true
```

config.yaml
-----------

The file `_config.yaml` serves as a configuration file for the `sanitize-prow-jobs` tool and can be automatically updated over time by [prow job dispatcher](https://github.com/openshift/ci-tools/tree/main/cmd/prow-job-dispatcher).

It stores and manage assignment of `Prowjobs` to specific build farm clustes.

The `sanitize-prow-jobs` tool utilizes this information to generate or update the `cluster` field directly within the `Prowjob` definitions.

```yaml
buildFarm:
  aws:
    build01:
      filenames:
      - openshift-multiarch-master-periodics.yaml
    build03:
      filenames:
      - openshift-installer-main-presubmits.yaml
  gcp:
    build02:
      filenames:
      - openshift-apiserver-operator-main-presubmits.yaml
    build04:
      filenames:
      - openshift-release-4.20-presubmits.yaml
cloudMapping:
  equinix-ocp-metal: aws
  openstack-vexxhost: aws
default: build01
determineE2EByJob: true
groups:
  app.ci:
    jobs:
    - branch-ci-openshift-config-master-group-update
    - branch-ci-openshift-config-master-org-sync
    paths:
    - infra-image-mirroring.yaml
    - '[^-]infra-periodics.yaml'
  build01:
    jobs:
    - periodic-build01-upgrade
    - release-openshift-ocp-installer-e2e-metal-serial-4.8
    paths:
    - infra-periodics-origin-release-images.yaml
  build02:
    jobs:
    - periodic-build02-upgrade
kvm:
- build02
- build04
sshBastion: build02
```
