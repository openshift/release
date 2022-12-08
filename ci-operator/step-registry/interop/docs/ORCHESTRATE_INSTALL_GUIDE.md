# (WIP) OpenShift CI Interop Scenario Orchestrate Install Guide<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Overview](#overview)
- [Orchestrate Product Install to Config \& Step-Registry](#orchestrate-product-install-to-config--step-registry)
  - [1. Run Containers against OpenShift Local](#1-run-containers-against-openshift-local)
  - [2. Populate the chain.yaml](#2-populate-the-chainyaml)
  - [3. Populate the commands.sh](#3-populate-the-commandssh)
  - [4. Add Secrets to Hashicorp Vault](#4-add-secrets-to-hashicorp-vault)
  - [5. Add Env Vars to Config](#5-add-env-vars-to-config)
  - [6. Submit PR](#6-submit-pr)

## Overview
Building off the scenario foundation that we put in place in the [Scenario Foundation Guide](SCENARIO_FOUNDATION_GUIDE.md) we will add everything that is needed for the Orchestrate phase for you scenario here.

The Orchestrate phase can be defined as anything needed to install and configure the product that is being tested on OpenShift.
## Orchestrate Product Install to Config & Step-Registry
To make sure you start out correctly please see the [Developers Guide](DEVELOPERS_GUIDE.md)
### 1. Run Containers against OpenShift Local
We want to first identify that the install containers are valid. A quick and cheap way to do this is to deploy a cluster locally using [OpenShift local](https://developers.redhat.com/products/openshift-local/overview). Once you have a cluster up make sure the containers and shell scripts provided by the product QE in the prerequisites step are working for operator install through product configuration.

### 2. Populate the chain.yaml

### 3. Populate the commands.sh

### 4. Add Secrets to Hashicorp Vault
See [SECRETS_GUIDE](SECRETS_GUIDE.md)

### 5. Add Env Vars to Config
The values and number of vars will differ from scenario to scenario but this will provide you the basics of the types of things needed in this section of the config. Collaboration between both parties will be critical during this step.

Take the follow test section in a config file as an example
```
tests:
- as: acm-interop-aws
  cron: 0 1 * * 1
  steps:
    cluster_profile: aws-cspi-qe
    env:
      BASE_DOMAIN: aws.interop.ccitredhat.com
      SUB_CHANNEL: release-2.6
      SUB_INSTALL_NAMESPACE: open-cluster-management
      SUB_PACKAGE: advanced-cluster-management
      SUB_SOURCE: redhat-operators
      SUB_TARGET_NAMESPACES: open-cluster-management
    test:
    - chain: interop-acm
    workflow: cucushift-installer-rehearse-aws-ipi-spot
```
We see 6 variables within `env:` all of which will be used by steps in either the `chain` or `worfklow` for this test. The first `BASE_DOMAIN` is used in the [cucushift-installer-rehearse-aws-ipi-spot](https://github.com/openshift/release/blob/a96f9f04d9baa0cb32a684c620e245a34d40326a/ci-operator/step-registry/cucushift/installer/rehearse/aws/ipi/spot/cucushift-installer-rehearse-aws-ipi-spot-workflow.yaml) workflow and the other 5 are used in the [operatorhub-subscribe step](https://github.com/openshift/release/blob/master/ci-operator/step-registry/operatorhub/subscribe/operatorhub-subscribe-ref.yaml). This step is called as a part of the `interop-acm` chain.

The idea behind placing environment variables here is so that we can use them in any container that is run to execute the workflows, chains, and steps that we point to in the `tests` stanza.

You will need to:
- Identify any need for environment variables in the products install and config.
  - Make sure that you are not hardcoding anything that may need to change later. If so review it and see if you can make it an env var.
- 

### 6. Submit PR
See [PR process](DEVELOPERS_GUIDE.md#pr-process)
