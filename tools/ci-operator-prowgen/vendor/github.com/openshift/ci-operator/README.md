# ci-operator

ci-operator automates and simplifies the process of building and testing
OpenShift component images (e.g. any `openshift/origin-{component}` images).

Given a Git repository reference and a component-specific configuration file,
describing base images and which images should be built and tested and how,
ci-operator builds the component images within an OpenShift cluster and runs the
tests. All artifacts are built in a new namespace named using a hash of all
inputs, so the artifacts can be reused when the inputs are identical.

ci-operator is mainly intended to be run inside a `Pod` in a cluster, triggered
by the Prow CI infrastructure, but it is also possible to run it as a CLI tool
on a developer laptop.

Note: ci-operator orchestrates builds and tests, but should not be confused
with [Kubernetes operator](https://coreos.com/operators/) which make managing
software on top of Kubernetes easier.

## Obtaining ci-operator

Currently, users must download the source and build it themselves:

```
$ git clone https://github.com/openshift/ci-operator.git
$ cd ci-operator
$ go build ./cmd/ci-operator
```

## Usage

ci-operator is mainly intended to be run automatically by the CI system, but
after you build it, you can also run it locally:

```
./ci-operator --config component.json --git-ref=openshift/{repo}@master
```

For more information about ci-operator options, use the `--help` parameter:

```
./ci-operator --help
```

## Onboarding a component to ci-operator and Prow

See [ONBOARD.md](ONBOARD.md#prepare-configuration-for-component-repo) for more
information about how to write component repository configuration file.

## OpenShift components using ci-operator

A number of [OpenShift
components](https://github.com/openshift/release/tree/master/ci-operator/config/openshift)
are already using ci-operator.
