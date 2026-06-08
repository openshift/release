HEADS UP:

You might want to use ../common/new-release.sh for adding a new branch.
https://github.com/openshift/release/blob/main/ci-operator/config/medik8s/common/new-release.sh

When adding or removing branches, or adding or removing OCP versions,
update branch protection in core-services/prow/02_config/medik8s/_prowconfig.yaml !
https://github.com/openshift/release/blob/main/core-services/prow/02_config/medik8s/_prowconfig.yaml
