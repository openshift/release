# (WIP) OpenShift CI Scenario Test Execution Guide<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Overview](#overview)
- [Add Product Test Execution to Step-registry](#add-product-test-execution-to-step-registry)
  - [1. Run Containers against OpenShift Local (if possible)](#1-run-containers-against-openshift-local-if-possible)
  - [2. Validate XMLs (if possible)](#2-validate-xmls-if-possible)
  - [3. Add Image Creation to Config](#3-add-image-creation-to-config)
  - [4. Create Execute Step Files](#4-create-execute-step-files)
  - [5. Run make update](#5-run-make-update)
  - [6. Push and Test Changes](#6-push-and-test-changes)
  - [7. Run Rehearsal Job](#7-run-rehearsal-job)
  - [8. Manually Validate XMLs](#8-manually-validate-xmls)

## Overview

## Add Product Test Execution to Step-registry
### 1. Run Containers against OpenShift Local (if possible)
We want to first identify that the test containers are valid. A quick and cheap way to do this is to deploy a cluster locally using [OpenShift local](https://developers.redhat.com/products/openshift-local/overview) and make sure the containers and shell scripts provided by the product QE in the prerequisites step are working.

There are likely to be cases where the product QEs test are not able to run on OpenShift Local for whatever reason. If this is the case feel free to move right to step #3

### 2. Validate XMLs (if possible)
After the test are executedon the OpenShift local cluster you should expect to find XMLs containing the test results (tests that produce valid XMLs are a part of the prerequisites). Locate the XMLs and make sure that ther are valid using an XML validator.

### 3. Add Image Creation to Config


### 4. Create Execute Step Files
Now we go back to the step-registry, specifically the execute directory that we've already created in the you should already have a scenario directory at
`ci-operator/step-registry/interop/{product_name}/`

### 5. Run make update
See [Make Update](DEVELOPERS_GUIDE.md#make-update)

### 6. Push and Test Changes
See [PR Process](DEVELOPERS_GUIDE.md#pr-process)

### 7. Run Rehearsal Job
See [Run Rehearsal Job](#run-rehearsal-job)

### 8. Manually Validate XMLs