# Prow job generator for ci-operator

The purpose of this tool is to reduce an amount of boilerplate that component
owners need to write when they use
[ci-operator](https://github.com/openshift/ci-operator) to set up CI for their
component. The generator is able to entirely generate the necessary Prow job
configuration from the ci-operator configuration file.

## Use

To use the generator, you need to build it:

```
$ go build ./tools/ci-operator-prowgen
```

### Full-repository

The generator can use the naming convention and directory structure of this
repository. Using this mode, all you need to do is to place your `ci-operator`
configuration file to the correct place in
[ci-operator/config](../../ci-operator/config) directory and then run the generator
with `--full-repo` parameter:

```
$ ./ci-operator-prowgen --full-repo
```

This will create Prow job configuration files under the
[ci-operator/jobs](../../ci-operator/jobs) directory, including one for your new
configuration file. The naming structure is the same like in the
`ci-operator/config` directory.

With `--full-repo` option, the generator uses `git` to detect a root directory
of the repo and then it constructs paths to both directories from it. It is
possible to not use the auto-detection and pass the paths directly too. This
call is identical to `./ci-operator-prowgen --full-repo`:

```
$ ./ci-operator-prowgen --config-dir ../../ci-operator/config/ --prow-jobs-dir ../../ci-operator/jobs/
```

### Single configuration

You can use `--source-config` option instead to pass a single `ci-operator`
configuration file. In this case, the generator will print the Prow job config
YAML to the standard output:

```
$ ./ci-operator-prowgen --source-config path/to/ci-operator/config.json
postsubmits:
  openshift/service-serving-cert-signer:
  - agent: kubernetes
(...)
```

Please note that elements of the file path are still used to identify
organization/repo/branch, so the path cannot be entirely arbirary. The path is
expected to have a `(anything)/ORGANIZATION/REPO/BRANCH.extension` form, just
likes path in [ci-operator/config](../..ci-operator/config) do.

## What does the generator create

The generator creates one presubmit and one postsubmit job for each test
specified in the ci-operator config file (in `tests` list):

```yaml
presubmits:
  ORG/REPO:
  - agent: kubernetes
    always_run: true
    branches:
    - master
    context: ci/prow/TEST
    decorate: true
    name: pull-ci-ORG-REPO-TEST
    rerun_command: /test TEST
    skip_cloning: true
    spec:
      containers:
      - args:
        - --artifact-dir=$(ARTIFACTS)
        - --target=TEST
        command:
        - ci-operator
        env:
        - name: CONFIG_SPEC
          valueFrom:
            configMapKeyRef:
              key: BRANCH.json
              name: ci-operator-ORG-REPO
        image: ci-operator:latest
        name: ""
        resources: {}
      serviceAccountName: ci-operator
    trigger: ((?m)^/test( all| TEST),?(\\s+|$))
postsubmits:
  ORG/REPO:
  - agent: kubernetes
    decorate: true
    name: branch-ci-ORG-REPO-TEST
    skip_cloning: true
    spec:
      containers:
      - args:
        - --artifact-dir=$(ARTIFACTS)
        - --target=TEST
        command:
        - ci-operator
        env:
        - name: CONFIG_SPEC
          valueFrom:
            configMapKeyRef:
              key: BRANCH.json
              name: ci-operator-ORG-REPO
        image: ci-operator:latest
        name: ""
        resources: {}
      serviceAccountName: ci-operator
```

Also, if the configuration file has a non-empty `images` list, one additional
presubmit and postsubmit job is generated with `--target=[images]` option passed
to `ci-operator` to attempt to build the component images. This postsubmit job
also uses the `--promote` option to promote the component images built in this
way.

## Develop

To run unit-tests, run:

```
$ go test ./ci-operator-prowgen
```
