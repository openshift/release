# ci-secret-bootstrap

The [ci-secret-bootstrap](https://github.com/openshift/ci-tools/tree/master/cmd/ci-secret-bootstrap) tool
populates secrets onto our ci-clusters based on the items saved in Bitwarden.
This directory contains the config file to run the tool.

The defined target `ci-secret-bootstrap` in [Makefile](../../Makefile) runs the tool as a container.

Be aware that the Makefile makes assumptions about how your contexts are set up and
that it will fail, should any of the contexts not be present:

* The context named `default` is assumed to point to the `api.ci` cluster
* The context named `build01` is assumed to point to the `build01` cluster
* The context named `app.ci` is assumed to point to the `app.ci` cluster
