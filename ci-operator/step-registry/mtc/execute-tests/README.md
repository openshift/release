# mtc-execute-tests-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Other](#other)
- [Custom Image - `mtc-runner`](#custom-image---mtc-runner)

## Purpose

Used to execute the MTC (Migration Toolkit for Containers) interoperability test suite and report the JUnit results for those tests.

## Process

1. Move the `oc` binary copied from the `cli` container to `/usr/bin/oc` to be used to login to the target cluster.
2. Extract the tar files for the following:
   1. The `clusters_data.tar.gz` file, which holds all of the cluster information for our two test clusters.
   2. The archive for the [`mtc-apps-deployer`](https://github.com/mtc-qe/mtc-apps-deployer) repository.
   3. The archive for the [`mtc-python-client`](https://github.com/mtc-qe/mtc-python-client) repository.
3. Create a Python virtual environment and install all required dependencies (including `mtc-apps-deployer` and `mtc-python-client`).
4. Login to the test cluster using `oc`
5. Execute the MTC interoperability tests via `pytest` and archive the results file in the `$ARTIFACT_DIR`.

## Prerequisite(s)

### Infrastructure

- Two provisioned clusters, a "source" and a "target" cluster.
  - "source" cluster should be 1 OCP release being the "target" cluster. For example: if we are running tests for the un-released 4.14 version of OCP, the "source" cluster should be version 4.13 and the "target" cluster should be version 4.13.

### Other

- The [`mtc-prepare-clusters` ref](../prepare-clusters/README.md) should be run prior to test execution.

## Custom Image - `mtc-runner`

- [Dockerfile](https://github.com/mtc-qe/mtc-e2e-qev2/blob/master/dockerfiles/interop/Dockerfile)
  
This image is used to execute the MTC interop test suite. The image copies in the [mtc-qe/mtc-e2e-qev2](https://github.com/mtc-qe/mtc-e2e-qev2) repository as well as a tar archive of the [mtc-qe/mtc-python-client](https://github.com/mtc-qe/mtc-python-client) and [mtc-qe/mtc-apps-deployer](https://github.com/mtc-qe/mtc-apps-deployer) repositories. These repositories are required to execute the tests but are private. Because cloning them would require maintaining a service account, it has been decided to promote and image for each repository in OpenShift CI. The images of these repositories are basic and only really contain the tar archive of the respective repositories. Using the promoted images, we can just copy the archive out of each image and into the `mtc-runner` image.