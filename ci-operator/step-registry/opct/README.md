# OPCT CI tests

This directory is the root of all [OPCT](https://github.com/redhat-openshift-ecosystem/provider-certification-tool) CI tooling.

Directory structure:

- cluster: holds references (`refs`) for all cluster variants used/required by VCSP or Platform External tested by OPCT
- flow: holds the workflows
- test: holds opct specific steps/tests
- upi: holds cluster provisioning steps, mostly referenced by `refs` or `workflows`.