# Supplemental CI images

These resources provide some supplemental images to be used in CI builds.

- `azure`: Used by [openshift/openshift-azure](../../../ci-operator/config/openshift/openshift-azure)
- `boilerplate`: Used by [openshift/boilerplate](../../../ci-operator/config/openshift/boilerplate)
- `cincinnati-ci`: Used by [openshift/cincinnati](../../../ci-operator/config/openshift/cincinnati)
- `content-mirror`: Used by [release-controller](../../build-clusters/common/release-controller)
- `coreos`: Used by [coreos](../../../ci-operator/config/coreos)
- `validation-images`: Used by [openshift/release](../../../ci-operator/config/openshift/release)
- `alpine_is.yaml`: Used by [openshift/ci-secret-mirroring-controller](../../../ci-operator/config/openshift/ci-secret-mirroring-controller)
- `ansible-runner-imagestream.yaml`: Used by [openshift/ocp-release-operator-sdk](../../../ci-operator/config/openshift/ocp-release-operator-sdk)
- `boskos.yaml`: Used by [openshift/ci-tools](../../../ci-operator/config/openshift/ci-tools)
- `cdi_builder_is.yaml`: Used by [openshift-kni/performance-addon-operators](../../../ci-operator/config/openshift-kni/performance-addon-operators)
- `cli-jq.yaml`: Used by [openshift/kubernetes](../../ci-operator/config/openshift/kubernetes)
- `cli-ocm.yaml`: Used by step registry (e.g. osd-create-create) when ocm is needed to create OpenShift Dedicated Clusters
- `golangci-lint_is.yaml`: Used by [openshift/ci-tools](../../../ci-operator/config/openshift/ci-tools)
- `html-proofer_is.yaml`, `hugo_is.yaml` and `nginx-unprivileged_is.yaml`: Used by [openshift/ci-docs](../../ci-operator/config/openshift/ci-docs)
- `insights-operator-tests.yaml`: Used by [openshift/insights-operator](../../ci-operator/config/openshift/insights-operator)
- `manage-clonerefs.yaml`: Used by [ProwJob/periodic-manage-clonerefs](https://github.com/openshift/release/blob/968b1dca270336a548f87ccca6d96c9fd7940fbe/ci-operator/jobs/infra-periodics.yaml#L8)
- `opm-builder.yaml`: Used by [openshift-kni/performance-addon-operators](../../../ci-operator/config/openshift-kni/performance-addon-operators)
- `rhscl-nodejs10.yaml`: Used by [openshift/origin-aggregated-logging](../../../ci-operator/config/openshift/origin-aggregated-logging)
- `sshd_build.yaml`: Used by [01_cluster/sshd-bastion](../../../clusters/build-clusters/01_cluster/sshd-bastion)
- `ubuntu.yaml`: Used by [kata-containers](../../../ci-operator/config/kata-containers)
- `redhat-operator-index`: Used by optional operators E2E tests
- `ansible-runner-ovirt`: used by ovirt infra cleanup periodic [job](../../../ci-operator/config/openshift/cluster-api-provider-ovirt/)
- `ovirt-prfinder`: used by ovirt prfinder periodic [job](../../../ci-operator/config/openshift/cluster-api-provider-ovirt/)