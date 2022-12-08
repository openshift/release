# (WIP) OpenShift CI Interop Scenario Foundation Guide<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Overview](#overview)
- [Create Foundational OpenShift CI Scenario Files](#create-foundational-openshift-ci-scenario-files)
  - [1. Create a directory within the config directory](#1-create-a-directory-within-the-config-directory)
  - [2. Create directories for the scenario in the step-registry](#2-create-directories-for-the-scenario-in-the-step-registry)
  - [3. Create the Scenario Chain](#3-create-the-scenario-chain)
  - [4. Create Config in Directory from Step #1.](#4-create-config-in-directory-from-step-1)
    - [Public](#public)
    - [Private (Coming Soon)](#private-coming-soon)
  - [5. Submit PR](#5-submit-pr)
  - [6. Post Merge](#6-post-merge)

## Overview
Here we will be submitting our first PR to the [openshift/release](https://github.com/openshift/release) repo.

We will create the file structure that is common to all interop scenarios.
The result will be a prow job that is capable of deploying an OCP cluster.
## Create Foundational OpenShift CI Scenario Files
To make sure you start out correctly please see the [Developers Guide](DEVELOPERS_GUIDE.md)
### 1. Create a directory within the config directory
    ci-operator/config/{organization}/{repository}
- **organization**: Github organization name that the test repository belongs to.
- **repository**: Test repository from org above.
### 2. Create directories for the scenario in the step-registry
    ci-operator/step-registry/interop/{product_name}
    ci-operator/step-registry/interop/{product_name}/orchestrate/
    ci-operator/step-registry/interop/{product_name}/execute/
    ci-operator/step-registry/interop/{product_name}/report/
- **product_name**: The shortname of the product under test.

### 3. Create the Scenario Chain
    ci-operator/step-registry/interop/{product_name}/interop-{product_name}-chain.yaml
- **product_name**: The shortname of the product under test.
```
chain:
  as: interop-{product_name}
  steps:
  - ref: operatorhub-subscribe
  - ref: interop-{product_name}-orchestrate
  documentation: |-
    Runs the {product_name} interop scenario
```

### 4. Create Config in Directory from Step #1.
    ci-operator/config/{organization}/{repository}/{organization}-{repository}-{branch}_{product_short_name}-ocp4.{xx}-interop.yaml

Creation of the config file can take two main paths based on what was decided in the [PREREQUISITES_GUIDE (Public vs Private Testing Section)](PREREQUISITES_GUIDE.md#public-vs-private-testing). This is based on whether or not your tests can be executed and have artifacts stored publicy or if they need to be hidden.

#### Public
Copy and Paste the [template](https://github.com/openshift/release/blob/master/ci-operator/config/rhpit/interop-tests/rhpit-interop-tests-master__installer-rehearse-4.12.yaml) into the file that you've created.

Now you will need to make changes to the following to make this file specific to your scenario

- TODO add section describing image version selection once in place
```
tests:
- as: {product_name}-interop-aws
  cron: 0 1 * * 1
  steps:
    cluster_profile: aws-cspi-qe
    env:
      BASE_DOMAIN: aws.interop.ccitredhat.com
    workflow: cucushift-installer-rehearse-aws-ipi
```
- **product_name**: The shortname of the product under test.

#### Private (Coming Soon)
Copy and Paste the [private template]()

### 5. Submit PR
See [PR process](DEVELOPERS_GUIDE.md#pr-process)

### 6. Post Merge
Once this is merged the cron trigger will be active. You will want to verify that the trigger works as we expect it to for the foundation of this scenario.

See [Triggering Guide](TRIGGERING_GUIDE.md) for more info.