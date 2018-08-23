This document describes how to add new CI jobs (utilizing ci-operator) for
OpenShift components to the OpenShift CI system. In general, two steps are
needed:

1. [Prepare configuration file](#prepare-configuration-for-component-repo),
   describing how ci-operator should build and test your component.
2. [Add new jobs to Prow](#add-prow-jobs), hooking ci-operator to important
   GitHub events for your repository.

This walkthrough covers a simple use case of hooking up a job running source
code level tests (unit, performance etc.) on pull requests on a component
repository. Although ci-operator can perform more sophisticated test steps than
simply running unit tests, these use cases are beyond the scope of this doc.

## Prepare configuration for component repo

The JSON configuration file describes how to build different images in a
testing pipeline for your repository. ci-operator has different *”targets”*
that describe the goal images to build, and later targets build on successfully
built earlier targets. You will probably want to write and test your config
file locally first, and test whether it builds all targets and runs all tests
as expected (you need to be logged in to a cluster, e.g. to
[api.ci](https://api.ci.openshift.org)):

```
./ci-operator --config config.json --git-ref openshift/<repo>@<revision>
```

After you make sure everything works, you need to create a subdirectory
of
[ci-operator/config/openshift](https://github.com/openshift/release/tree/master/ci-operator/config/openshift)
in the [openshift/release](https://github.com/openshift/release/) repository for
your component and put the config file there.

### Source code image target

By default, ci-operator builds the `src` target image, expected by later targets
to contain the source code of the component together with its build
dependencies. Using [cloneref](https://github.com/kubernetes/test-infra/tree/master/prow/cmd/clonerefs)
, ci-operator fetches the refs to be tested from the component repository
and injects the source code into the base image specified by the
`test_base_image` key.  The base image should contain all build dependencies of
the tested component, so the it will often be a `openshift/release:<tag>` image.

```json
{
  "test_base_image": {
    "cluster": "https://api.ci.openshift.org",
    "namespace": "openshift",
    "name": "release",
    "tag": "golang-1.10"
  }
}
```

Given your component can be built in the context of the `openshift/release`
image, you can test building the `src` target:

```
$ ./ci-operator --config example.json --git-ref=openshift/<component>@<revision> --target=src
```

### Test targets

Test target images are built over earlier targets. The targets are specified in
a `tests` array (so it is possible to specify multiple test targets). Here is an
example of two test targets, each performing a different test by calling
different `make` target in a `src` image (of course, a `Makefile` in your
component repository would need to have these targets for this to work).

```json
{
  "tests": [
    {
      "as": "unit",
      "from": "src",
      "commands": "make test-unit"
    },
    {
      "as": "performance",
      "from": "src",
      "commands": "make test-performance"
    }
  ]
}
```

By default, ci-operator runs all specified test targets, building all their
dependencies (and transitively, their dependencies) before. You can limit the
execution to build just one or more targets using the `--target` option.

### Intermediary binary targets

Two test targets in the previous example assume their `make` targets take care
of full build from source till the actual test. This is often the case, but it
is ineffient because each test target performs the build separately. CI
operator can create `bin` and `test-bin` targets for the test targets to share
by providing `binary_build_commands` and `test_binary_build_commands`
respectively. Note that ci-operator allows separate `bin` and `test-bin`
targets because often the compilation process is different for “normal” and
test binaries, for example in Go you might want do compile in a different way
to test for race conditions.

Here, `unit` and `integration` targets will both be built from a `test-bin`
image, which will be a result of running `make instrumented-build` over a `src`
image, while `performance` test target will be run from a `bin` image:

```json
{
  "binary_build_commands": "make build",
  "test_binary_builds_commands": "make instrumented-build",
  "tests": [
    {
      "as": "unit",
      "from": "test-bin",
      "commands": "make test-unit"
    },
    {
      "as": "integration",
      "from": "test-bin",
      "commands": "make test-integration",
    },
    {
      "as": "performance",
      "from": "bin",
      "commands": "make test-performance"
    }
  ]
}
```


### Submit the configuration file to `openshift/release`

When you describe the targets for your component in the configuration file, you
will need to add the file to the
[openshift/release](https://github.com/openshift/release) repository,
specifically to its `ci-operator/config/openshift` subdirectory
[tree](https://github.com/openshift/release/tree/master/ci-operator/config/openshift).
Each OpenShift component has a separate directory there, and there is a
configuration file in it per branch of the repository under test (all files
should be in the `master` branch of the `openshift/release` repository).

### Images targets, end-to-end tests and more

Building the source code and running unit tests is basic use case for
ci-operator. In addition to that, ci-operator is able to build component images,
provision test clusters using them and run end-to-end tests on them. These use
cases would use more features in both configuration file and Prow job and would
not fit into this document. We will provide more documentation describing other
use cases soon.

## Add Prow jobs

Once the config file is prepared and commited, you can add a Prow job that will
run ci-operator to build the selected targets before or after a PR is merged (or
even periodically). You can find information about how to create Prow jobs in
[test-infra
documentation](https://github.com/openshift/test-infra/tree/master/prow#how-to-add-new-jobs).
Long story short, you need to add a new job definition to the [config
file](https://github.com/openshift/release/blob/master/cluster/ci/config/prow/config.yaml)
in `openshift/release` repository. You need to add a job definition to the
appropriate section of either `presubmits`, `postsubmits` or `periodicals` key
of the config file:

```yaml
presubmits:
  openshift/<repo>:
  - name: <unique-name-of-presubmit-repo>
    agent: kubernetes
    context: ci/prow/unit
    branches:
    - master
    rerun_command: "/test unit"
    always_run: true
    trigger: "((?m)^/test( all| unit),?(\\s+|$))"
    decorate: true
    skip_cloning: true
    spec:
      serviceAccountName: ci-operator
      containers:
      - name: test
        image: ci-operator:latest
        env:
        - name: CONFIG_SPEC
          valueFrom:
            configMapKeyRef:
              name: ci-operator-openshift-<repo>
              key: <name of config file in ‘ci-operator/config/openshift/repo>
        command:
        - ci-operator
        args:
        - --target=unit
        - <more ci-operator arguments>
```

Unfortunately, this is a lot of boilerplate in already a huge file. We hope we
will be able to reduce the necessary amount of configuration soon.
