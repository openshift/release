#!/usr/bin/env groovy

library "github.com/openshift/release-library@master"

testPipeline(
  /* name      */ "py35-unit",
  /* build job */ "ci-openshift-ansible-build",
  /* base tag  */ "tox",
  /* test cmd  */ "./.tox/py35-unit/bin/pytest",
  /* limits    */ "1Gi", "1000m"
)
