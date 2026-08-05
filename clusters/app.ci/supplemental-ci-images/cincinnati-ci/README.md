# Project declarations for the openshift/cincinnati CI

This service declares resources used by the cincinnati CI jobs.

These namespaces and their resources are dedicated to the cincinnati CI jobs.
Initially we're interested in using it for secrets and container images.

Namespace and their purposes:
* `cincinnati-ci`: stores static CI secrets and will be used to test the Graph-Builder's
  authentication mechanism towards Docker v2 compatible registries.
* `cincinnati-ci-public`: will be used to host publicly accessible container images for various test cases.
