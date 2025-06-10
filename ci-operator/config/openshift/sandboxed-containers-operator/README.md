This directory contain the ci-operator configuration files to generate the Prow jobs for the Openshift Sandboxed Containers (OSC) operator.

## Downstream

The jobs in this category are used to test the downstream builds of OSC. Find their defintion on the yaml files marked with `__downstream` in their name.

The downstream jobs use custom steps, chains and workflows hosted at [here](../../../step-registry/sandboxed-containers-operator/). Please refer to [their documentation](../../../step-registry/sandboxed-containers-operator/README.md) for further information.
