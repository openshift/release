# ci-secret-generator

The [ci-secret-generator](https://github.com/openshift/ci-tools/tree/master/cmd/ci-secret-generator) tool
populates secrets onto our BitWarden vault based on the live data in our clusters.
This directory contains [the config file](./_config.yaml) to run the tool.

The defined target `ci-secret-generator` in [Makefile](../../Makefile) runs the tool as a container.

Be aware that the Makefile makes assumptions about how your contexts are set up and
that it will fail, should any of the contexts which are used as cluster in its config file not be present: