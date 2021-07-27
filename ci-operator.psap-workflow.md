## https://steps.ci.openshift.org/ci-operator-reference
## https://docs.ci.openshift.org/docs/architecture/ci-operator/
# ci-operator/config/openshift-psap/ci-artifacts/openshift-psap-ci-artifacts-master.yaml

* based on this repo/branch:

```
zz_generated_metadata:
  branch: master
  org: openshift-psap
  repo: ci-artifacts
```

* and this base image:

```
base_images:
  os:
    name: ubi
    namespace: ocp
    tag: "8"
```

* build the ci-artifacts image with this dockerfile:

```
images:
- dockerfile_path: build/Dockerfile
  from: os
  to: ci-artifacts
```

* then run these periodic tests:

```
tests:
- as: gpu-operator-e2e
  cron: 0 */23 * * *
```

```
  steps:
    cluster_profile: aws
    test:
    - as: nightly
      cli: latest
      commands: run gpu-ci <-- here is the test command
      from: ci-artifacts
    workflow: ipi-aws
```

# ./ci-operator/jobs/openshift-psap/ci-artifacts/openshift-psap-ci-artifacts-master-presubmits.yaml

* Run this on MR for `openshift-psap/ci-artifacts` repository:

```
presubmits:
  openshift-psap/ci-artifacts:
```

* run the CI-operator "images" command on MR to the the master branch:

```
    always_run: true
    cluster: build01
    branches:
    - master
    context: ci/prow/images
    spec:
      containers:
      - command:
        - ci-operator
        args:
        - ...
        - --target=[images]
        image: ci-operator:latest
```

* rerun it manually with this command:

```
    rerun_command: /test images
```

* run the yamllint command on MR to the master branch

```
    always_run: true
    cluster: build01
    branches:
    - master
    context: ci/prow/yamllint
    spec:
      containers:
      - command:
        - yamllint
        args:
        - -c
        - configs/.yamllint.conf
        - playbooks
        - roles

```

# ./ci-operator/jobs/openshift-psap/special-resource-operator/openshift-psap-special-resource-operator-release-4.6-postsubmits.yaml

* After MR have been merged in openshift-psap/special-resource-operator on a given branch:

```
postsubmits:
  openshift-psap/special-resource-operator:
  branches:
    - ^release-4\.6$
```

* Run this command:

```
    spec:
      containers:
      - command:
        - ci-operator
        args:
        - ...
        - --target=[images]
        image: ci-operator:latest
```

# ./ci-operator/jobs/openshift-psap/ci-artifacts/openshift-psap-ci-artifacts-master-periodics.yaml

* Periodically run these tests

```
periodics:
- agent: kubernetes
  cluster: api.ci
  cron: 0 */23 * * *
  extra_refs:
  - base_ref: master
    org: openshift-psap
    repo: ci-artifacts
  spec:
    containers:
    - command:
      - ci-operator
      args:
      - ...
      - --target=gpu-operator-e2e
```
