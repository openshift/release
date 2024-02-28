# Identity Providers (IDP) Configuration for OpenShift Prow CI

## Introduction

This guide outlines the procedures and scripts for configuring Identity Providers (IDP) within the OpenShift Prow CI ecosystem. Focused on automating IDP setups for Htpasswd, OpenLDAP, and FreeIPA, our goal is to streamline user authentication processes across CI/CD operations.

## Current Focus

We are automating the configuration of three primary IDP solutions:

- **Htpasswd and OpenLDAP**: Both are fully automated, providing seamless setup of user/password pairs.
- **FreeIPA**: Automation is in progress to extend our IDP support further.
- **Other IDPs**: They are yet in backlog and will be added in future.

## Available IDP Configurations

### Htpasswd

- **Automation Status**: Fully Automated
- **Purpose**: User setup via Htpasswd Identity.
- **Script URL**: [Htpasswd IDP Script](https://github.com/openshift/release/blob/master/ci-operator/step-registry/idp/htpasswd/idp-htpasswd-ref.yaml)

### OpenLDAP

- **Automation Status**: Fully Automated
- **Purpose**: User setup via OpenLDAP Identity.
- **Script URL**: [OpenLDAP IDP Script](https://github.com/openshift/release/blob/master/ci-operator/step-registry/idp/openldap/idp-openldap-ref.yaml)

### FreeIPA

- **Automation Status**: In Progress
- **Purpose**: User configuration through FreeIPA Identity.

## Pre-requisites

Before configuring an IDP, ensure:

- A deployed OpenShift cluster.
- The `$USERS` environmental variable is not set and no other IDP configuration is set. The scripts check `$USERS` environment variable from runtime environment and check existing IDP configuration.

## Features

### Runtime Environment Checks and Configuration

To simplify test coverage for Auth IDPs, the scripts only configures one single IDP in a single Prow job.

### Password Management

Passwords for test users are dynamically generated.

### Additional Features

- **Environment Variable Export**: Generated user/password pairs are added to the shared runtime environment file to be exported as `$USERS` environment variable.

## Integration in CI Chains

### Htpasswd Identity Configuration

Included in the `openshift-e2e-test-qe*` chains by default, highlighting our commitment to secure user authentication in CI processes.

### OpenLDAP Identity Configuration

Configured for selected Prow jobs for selected CI profiles. To configure it in new a Prow job, add the `idp-openldap` step before executing the `openshift-e2e-test-qe*` chain, which will make the `idp-htpasswd` step not configure an htpasswd IDP any more.

## Future Directions & Contributions

We're working on FreeIPA automation and extending support for user additions via IDP to Ginkgo test cases. Contributions and feedback are welcome to enhance our testing environment within OpenShift Prow CI.
