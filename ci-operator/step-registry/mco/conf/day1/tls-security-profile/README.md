# tls-security-profile-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To create day-1 manifest having apiserver which contain custom tlsSecurityProfile setting

Example for the custom tlsProfile configuration 

```
- as: aws-ipi-tlssecurityprofile-custom-f28
  cron: 14 4 13 * *
  steps:
    cluster_profile: aws-qe
    dependencies:
      OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE: release:multi-latest
    env:
      BASE_DOMAIN: qe.devcluster.openshift.com
      COMPUTE_NODE_TYPE: m6g.xlarge
      CONTROL_PLANE_INSTANCE_TYPE: m6g.xlarge
      MCO_CONF_DAY1_TLS_PROFILE: '{"type": "Custom", "custom": { "ciphers": ["ECDHE-ECDSA-CHACHA20-POLY1305",
        "ECDHE-RSA-CHACHA20-POLY1305", "ECDHE-RSA-AES128-GCM-SHA256", "ECDHE-ECDSA-AES128-GCM-SHA256"],
        "minTLSVersion": "VersionTLS11"}}'
      OCP_ARCH: arm64
    test:
    - chain: openshift-e2e-test-qe
    workflow: cucushift-installer-rehearse-aws-ipi-tlssecurityprofile
```


## Process

This script creates a custom tlsSecurityProfile.

## Prerequisite(s)

### Infrastructure

### Environment Variables

- `MCO_CONF_DAY1_TLS_PROFILE`
  - **Definition**: It is used to set Custom tlsSecurityProfile

