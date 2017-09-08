# Pipelines to Build and Test OpenShift Origin

This directory contains templates and artifacts to build and test origin.

## Prerequisites
To run any test or build job, the following must be in place:
- Jenkins with the appropriate plugins. To setup run:
  ```
  oc new-app -f https://raw.githubusercontent.com/openshift/release/master/jenkins/setup/jenkins-setup-template.yaml
  ```
- `release-ci` tool and related Jenkins slave image. To build locally:
  ```sh
  oc new-app -f https://raw.githubusercontent.com/openshift/release/master/tools/build/build-tools.yaml
  ```
- The origin base image to use for all clone and build operations. To build locally:
  ```sh
  oc new-app -f https://raw.githubusercontent.com/openshift/release/master/cluster/ci/origin/base-image-pipeline.yaml
  ```
  **Note:** The above pipeline should likely be scheduled to run on a regular basis to keep an updated 
  base image of Origin. To build, simply run:
  ```sh
  oc start-build base-image-pipeline
  ```
  or start the pipeline in Jenkins itself.

## Pipelines
The following pipelines are available in this directory:
- Build Origin
- Verification Tests
- Unit Tests

Both verification tests and unit tests will wait for a source or binaries image to be available. These are produced by the build pipeline. The three piplines can be started simultaneously.

To instantiate the pipelines, run:
```sh
oc new-app -f https://raw.githubusercontent.com/openshift/release/master/cluster/ci/origin/build-origin-pipeline.yaml
oc new-app -f https://raw.githubusercontent.com/openshift/release/master/cluster/ci/origin/verify-origin-pipeline.yaml
oc new-app -f https://raw.githubusercontent.com/openshift/release/master/cluster/ci/origin/unit-test-origin-pipeline.yaml
```

The above commands do not start the pipelines, simply create them. To build and test a specific PULL_REFS value:
```sh
export PULL_REFS="master:631de377402885b335270892c230f5aca83b3a56"
oc start-build build-origin -e PULL_REFS="${PULL_REFS}"
oc start-build verify-origin -e PULL_REFS="${PULL_REFS}"
oc start-build ut-origin -e PULL_REFS="${PULL_REFS}"
```
Or they can be started directly in Jenkins where PULL_REFS is passed as a parameter.

## Hacking

To test changes to these pipelines in your own branch, push your changes to your own fork of the `release` repository and instantiate them with your own fork URL and branch:

```sh
export FORK="myname"
export BRANCH="my_changes"

oc new-app -f "https://raw.githubusercontent.com/${FORK}/release/${BRANCH}/jenkins/setup/jenkins-setup-template.yaml" \
           -p SOURCE_URL="https://github.com/${FORK}/release.git" -p SOURCE_REF="${BRANCH}"
oc new-app -f https://raw.githubusercontent.com/${FORK}/release/${BRANCH}/tools/build/build-tools.yaml \
           -p RELEASE_URL="https://github.com/${FORK}/release.git" -p RELEASE_REF="${BRANCH}"
oc new-app -f https://raw.githubusercontent.com/${FORK}/release/${BRANCH}/cluster/ci/origin/base-image-pipeline.yaml \
           -p RELEASE_SRC_URL="https://github.com/${FORK}/release.git" -p RELEASE_SRC_REF="${BRANCH}"
oc new-app -f https://raw.githubusercontent.com/${FORK}/release/${BRANCH}/cluster/ci/origin/build-origin-pipeline.yaml \
           -p RELEASE_SRC_URL="https://github.com/${FORK}/release.git" -p RELEASE_SRC_REF="${BRANCH}"
oc new-app -f https://raw.githubusercontent.com/${FORK}/release/${BRANCH}/cluster/ci/origin/verify-origin-pipeline.yaml \
           -p RELEASE_SRC_URL="https://github.com/${FORK}/release.git" -p RELEASE_SRC_REF="${BRANCH}"
oc new-app -f https://raw.githubusercontent.com/${FORK}/release/${BRANCH}/cluster/ci/origin/unit-test-origin-pipeline.yaml \
           -p RELEASE_SRC_URL="https://github.com/${FORK}/release.git" -p RELEASE_SRC_REF="${BRANCH}"
```

## Code Organization

This directory contains templates to intantiate the main pipelines, and contains the following subdirectories:
- `images`: contains Dockerfile builds for the base image, source, binaries, rpms, etc
- `config`: contains OpenShift templates for builds and test pods. These are instantiated by the pipelines.
- `pipelines`: contains the Jenkinsfile source for each of the pipelines defined in this directory.