# ci-secret-generator

The [ci-secret-generator](https://github.com/openshift/ci-tools/tree/master/cmd/ci-secret-generator) tool
populates secrets onto Vault based on the live data in our clusters.
This directory contains [the config file](./_config.yaml) to run the tool.

The defined target `ci-secret-generator` in [Makefile](../../Makefile) runs the tool as a container.

Be aware that the Makefile makes assumptions about how your contexts are set up and
that it will fail, should any of the contexts which are used as cluster in its config file not be present.

## Service account `kubeconfig`s

Following the deprecation and removal of `ServiceAccount` token `Secret`s in
Kubernetes 1.24, `kubeconfig` files are now generated in two parts:

- a dynamic, relatively short-lived token, which is constantly regenerated
- a fixed `kubeconfig` file which references the token file and contains the
  remaining configuration

Both of these files are created by the generator.  The token file is created
using the `oc create token` command.  The `kubeconfig` is a simple text file
created by a [script][oc_create_kubeconfig.sh] in `ci-tools`.  Both of these
files are placed in Vault by the generator and later propagated to the clusters.

All generated tokens are bound to a secret to facilitate rotation in case they
are accidentally revealed.  See [`token-rotation.md`][token_rotation.md] for
details.

[oc_create_kubeconfig.sh]: https://github.com/openshift/ci-tools/blob/master/images/ci-secret-generator/oc_create_kubeconfig.sh
[token_rotation.md]: ../../docs/dptp-triage-sop/token-rotation.md
