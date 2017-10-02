# OpenShift Release Tools

This repository contains the process tooling for OpenShift releases.

## Prow

Prerequisites:
* `ci` namespace exists
* `PROXY_AUTH_PASS` is the password for authenticating with `jenkins-proxy`
* `BASIC_AUTH_PASS` is the password for authenticating with https://ci.openshift.redhat.com/jenkins/
* `BEARER_TOKEN` is the token for authenticating with https://jenkins-origin-ci.svc.ci.openshift.org
* `HMAC_TOKEN` is used for decrypting Github webhook payloads
* `OAUTH_TOKEN` is used for adding labels and comments in Github
* `RETEST_TOKEN` is used by the retester periodic job to rerun tests for PRs

Ensure the aforementioned requirements are met and stand up a prow cluster:
```
make prow
```

For more information on prow, see the upstream [documentation](https://github.com/kubernetes/test-infra/tree/master/prow#prow).
