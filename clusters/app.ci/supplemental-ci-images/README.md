# Supplemental CI images

These resources provide some supplemental images to be used in CI builds.
- `azure`: Used by [openshift/openshift-azure](../../../ci-operator/config/openshift/openshift-azure)
- `cincinnati-ci`: Used by [openshift/cincinnati](../../../ci-operator/config/openshift/cincinnati)
- `cli-jq.yaml`: Used by [openshift/kubernetes](../../ci-operator/config/openshift/kubernetes)
- `content-mirror`: Used by [release-controller](../../build-clusters/common/release-controller)
- `html-proofer_is.yaml`, and `nginx-unprivileged_is.yaml`: Used by [openshift/ci-docs](../../ci-operator/config/openshift/ci-docs)
- `openvpn`: Used by `ci-operator` for clusters profiles which request a [VPN connection](https://docs.ci.openshift.org/docs/architecture/step-registry/#vpn-connection).
- `opm-builder.yaml`: Used by [openshift-kni/performance-addon-operators](../../../ci-operator/config/openshift-kni/performance-addon-operators)
- `redhat-operator-index`: Used by optional operators E2E tests
- `sshd_build.yaml`: Used by [01_cluster/sshd-bastion](../../../clusters/build-clusters/01_cluster/sshd-bastion)
- `telco-bastion`: used by cnf-features-deploy periodic [job](../../../ci-operator/config/openshift-kni/cnf-features-deploy/)
- `validation-images`: Used by [openshift/release](../../../ci-operator/config/openshift/release)
- `hypershift`: Used by DPTP Hypershift-related workflows (e.g., ../../../ci-operator/step-registry/hypershift/hive)
- `govulncheck`: Used by CRT to be notified about go dependency vulnerabilities (e.g. presubmits for ../../../ci-operator/config/openshift/release-controller)
