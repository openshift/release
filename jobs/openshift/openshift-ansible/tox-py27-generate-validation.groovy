#!/usr/bin/env groovy

library "github.com/openshift/release-library@master"

testPipeline(
  /* name      */ "py27-generate-validation",
  /* build job */ "ci-openshift-ansible-build",
  /* base tag  */ "tox",
  /* test cmd  */ "./.tox/py27-generate_validation/bin/python setup.py generate_validation",
  /* limits    */ "1Gi", "1000m"
)
