#!/usr/bin/env groovy

library "github.com/stevekuznetsov/release-library@skuznets/image-builds"

extendedTestPipeline(
  /* buildJob  */ "ci-image-registry-build",
  /* deployJob */ "ci-image-registry-deploy",
  /*  testTag  */ "",
  /*  testCmd  */ "",
)
