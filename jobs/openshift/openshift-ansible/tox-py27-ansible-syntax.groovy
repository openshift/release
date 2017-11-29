#!/usr/bin/env groovy

library "github.com/openshift/release-library@master"

testPipeline(
  /* name      */ "py27-ansible-syntax",
  /* build job */ "ci-openshift-ansible-build",
  /* base tag  */ "tox",
  /* test cmd  */ "ANSIBLE_CACHE_PLUGIN=memory ./.tox/py27-ansible_syntax/bin/python setup.py ansible_syntax",
  /* limits    */ "1Gi", "1000m"
)
