# (WIP) OpenShift CI Interop Scenario Prerequistes Guide<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Overview](#overview)
- [Prerequisites](#prerequisites)
  - [Resources](#resources)
  - [Public vs Private Testing](#public-vs-private-testing)
    - [Public](#public)
    - [Private](#private)
  - [Git User Readiness](#git-user-readiness)
  - [Git Org \& Repo Readiness](#git-org--repo-readiness)
  - [Containerized Product Install \& Config](#containerized-product-install--config)
  - [Containerized Test Environment Config \& Execution](#containerized-test-environment-config--execution)
  - [Valid Test Output](#valid-test-output)
  - [Documented Tests](#documented-tests)

## Overview
This doc is meant to be used by Product QE teams to prepare themselves and their testing repositories to run within OpenShift CI.

## Prerequisites
1. Resources
2. Public vs Private Testing
3. Git User Readiness
4. Git Org & Repo Readiness
5. Containerized Product Install & Config
6. Containerized Test Environment Config & Execution
7. Valid Test Output
8. Documented Tests

### Resources
- Engineers that are assigned to work on & hold shared responsibility for product onboarding, execution and future maintenance.
- Please see the [RACI Chart](TODO) to understand the roles & responsibillities for this onboarding.

### Public vs Private Testing
Running in OpenShift CI is by default upstream and open to the public. This may be new for many product QE teams and the evaluation of whether or not you can run your test suite upstream should not be taken lightly. Based on the outcome of this decision the onboarding will take a different path. The two paths, public and private, are outlined below.

Upstream testing is the preferred approach, you will need to present a valid case as to why your test suite cannot be made public in order to pursue the private path. Regardless of which path you take there will need to be sign-off from both parties in the official prerequisites completion doc.
#### Public
- Sign-off from both parties that the tests can be executed publicly.
- Logged output does not contain sensitive information.
- Confirmation that the tests can be run outside of the company firewall and doesn't rely on internal services.
#### Private
- Produce a rationale as to why the test suite cannot be run upstream (specific security issues, company secrets, ..etc).
- Attempt to resolve any issue that is forcing this scenario to be private, we will need to be critical about these limitations and discuss if they can be remedied (we can work together with you to improve the testing process if needed and time allows.
- Sign-off from both parties approving this rationale.

### Git User Readiness
- Add engineers github username to the openshift organization ([follow this guide](https://source.redhat.com/groups/public/atomicopenshift/atomicopenshift_wiki/openshift_onboarding_checklist_for_github)).

### Git Org & Repo Readiness
- A Github organization that can be used for testing within OpenShift CI
- A Github test repo within the github organization specified in the step above.
- The test repo itself should hold the necessary container image(s) used to setup the testing environment.
- [Add Openshift-ci-robot & openshift-merge-robot](https://docs.ci.openshift.org/docs/how-tos/onboarding-a-new-component/#granting-robots-privileges-and-installing-the-github-app) to your Github organization.

### Containerized Product Install & Config
- The product can be installed via the operator hub.
- A method to install the operator from the operator hub executed as a container.
  - If your product is able to be installed using the steps existing in the  [operatorhub-subscribe ref](https://github.com/openshift/release/tree/master/ci-operator/step-registry/operatorhub/subscribe) than we can make use of that instead.
- Product install configuration (anything that needs to be done post operator install) executed within a container (maintained by the product QE team in upstream repo or reachable registry).
- Identified all env vars and secrets needed for install.

Please see the [Container Creation Guide](CONTAINER_CREATION_GUIDE.md) for general guidance when creating your scenarios test container(s).



### Containerized Test Environment Config & Execution
- Product test environment setup executed within a container (maintained by product QE team in test repo or reachable registry).
- A script or command that can be run against the test setup container to trigger the necessary test cases.
- Identified all env vars and secrets needed for testing.

Please see the [Container Creation Guide](CONTAINER_CREATION_GUIDE.md) for general guidance when creating your scenarios test container(s).

### Valid Test Output
- Produce J-unit XMLs in a valid format for each test that is executed.
  - This will be needed for import into Report Portal.

### Documented Tests
- Helpful documentation for tests that are being run that we can link to in the scenarios README.md
