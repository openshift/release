# OpenShift Release Tools

This repository contains the process tooling for OpenShift releases, implemented
with an [OpenShift cluster](https://api.ci.openshift.org/console/), plus a
Jenkins instance.

## Openshift CI infra

Prerequisites:
* various credentials need to be present in your environment
  - required prow credentials can be found in the [prow-secrets](https://github.com/openshift/release/blob/17fb58ec3c10a407f8b895b5fdba6a0796bc2677/Makefile#L42-L55) target
* ensure you run as `system:admin`

`make all` then will deploy all the necessary CI components.

For more information on prow, see the upstream [documentation](https://github.com/kubernetes/test-infra/tree/master/prow#prow).

## More information on OpenShift CI

See [aos-cd-jobs](https://github.com/openshift/aos-cd-jobs/) for more
information about the OpenShift Jenkins instance, which many Prow
jobs in this repository trigger.

Red Hat employees should also consult the [CI Overview](https://mojo.redhat.com/docs/DOC-1165629).

## Contributing changes

Looking at [the active pull requests](https://github.com/openshift/release/pulls) should
give some examples of how things work.  After your change to the git repository is merged, the
`config-updater` app will automatically apply changes to the live cluster.
