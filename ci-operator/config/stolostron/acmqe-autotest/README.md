# stolostron-acmqe-autotest<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [General Information](#general-information)
- [Purpose](#purpose)
- [Interop Testing](#interop-testing)

## General Information

- **Repositories**: 
  - [stolostron/acmqe-autotest](https://github.com/stolostron/acmqe-autotest)
  - [stolostron/clc-ui-e2e](https://github.com/stolostron/clc-ui-e2e)
  - [stolostron/acmqe-grc-test](https://github.com/stolostron/acmqe-grc-test)
  - [stolostron/application-ui-test](https://github.com/stolostron/application-ui-test)
  - [stolostron/observability_core_automation](https://github.com/stolostron/observability_core_automation)

## Purpose

Central location for running ACM QE's automation. Configs can be built here to accomplish many different test types.

## Interop Testing

- **Config Name**: `stolostron-acmqe-autotest-main__vboulos-acm-ocp4.12-lp-interop.yaml`
  - This config tests the following
  - **Cluster Provisioning and Deprovisioning**: `acm-ipi-aws`
    - The acm-ipi-aws workflow
  - **Test Setup, Execution, and Reporting Results**: `acm-interop-aws`
  - **ACM Base Images**: These images are responsible for bringing the test code & environment for each part of the ACM scenario
    - `fetch-managed-clusters`: 
    - `clc-ui-e2e`:
    - `acmqe-grc-test`:
    - `application-ui-test`:
    - `observability-core-automation`: