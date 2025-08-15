# opp-cnv-ui-test-vm-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Others](#others)

## Purpose

Test Openshift Virtualization pages on ACM cluster, make sure the UI flow works smoothly on ACM & CNV integrity environment.


## Process

- This ref runs a [script from product QE's repo](https://github.com/kubevirt-ui/kubevirt-plugin/blob/main/test-cypress.sh) that kicks off Cypress tests.

## Requirements


### Infrastructure

- git clone [repo](https://github.com/kubevirt-ui/kubevirt-plugin.git)
- ./test-cypress.sh -s "tests/acm.cy.ts"

### Others