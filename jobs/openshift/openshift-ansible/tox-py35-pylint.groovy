#!/usr/bin/env groovy

library "github.com/openshift/release-library@master"

testPipeline(
  /* name      */ "py35-pylint",
  /* build job */ "ci-openshift-ansible-build",
  /* base tag  */ "tox",
  /* test cmd  */ "./.tox/py35-pylint/bin/python setup.py lint",
  /* limits    */ "1Gi", "1000m"
)
