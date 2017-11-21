#!/usr/bin/env groovy

library "github.com/openshift/release-library@master"

testPipeline(
  /* name      */ "py35-flake8",
  /* build job */ "ci-openshift-ansible-build",
  /* base tag  */ "tox",
  /* test cmd  */ "./.tox/py35-flake8/bin/flake8",
  /* limits    */ "1Gi", "1000m"
)
