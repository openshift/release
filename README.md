# OpenShift Release Tools

This repository contains the process tooling for OpenShift releases.

## Openshift CI infra

Prerequisites:
* various credentials need to be present in your environment
  - required prow credentials can be found in the [prow-secrets](https://github.com/openshift/release/blob/17fb58ec3c10a407f8b895b5fdba6a0796bc2677/Makefile#L42-L55) target
* ensure you run as `system:admin`

`make all` then will deploy all the necessary CI components.

For more information on prow, see the upstream [documentation](https://github.com/kubernetes/test-infra/tree/master/prow#prow).

TODO: Cross-link to CI overview doc.