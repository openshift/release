# ci-secret-bootstrap

The [ci-secret-bootstrap](https://github.com/openshift/ci-tools/tree/master/cmd/ci-secret-bootstrap) tool
populates secrets onto our ci-clusters based on the items saved in Vault.
This directory contains [the config file](./_config.yaml) to run the tool.

The defined target `ci-secret-bootstrap` in [Makefile](../../Makefile) runs the tool as a container.

Be aware that the Makefile makes assumptions about how your contexts are set up and
that it will fail, should any of the contexts which are used as cluster in its config file not be present.

## Service account `kubeconfig`s

Following the deprecation and removal of `ServiceAccount` token `Secret`s in
Kubernetes 1.24, `kubeconfig` files are now generated in two parts.  See the
[`ci-secret-generator` documentation][ci_secret_generator] for details.

[ci_secret_generator]: ../ci-secret-generator/README.md#service-account-kubeconfig
