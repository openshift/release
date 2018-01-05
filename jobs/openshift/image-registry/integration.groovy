#!/usr/bin/env groovy

library "github.com/stevekuznetsov/release-library@skuznets/image-builds"

testPipeline(
  /*      name */ "unit",
  /* build job */ "ci-image-registry-build",
  /*  base tag */ "test-bin",
  /*  test cmd */ "make test-integration",
  /*    limits */ "1Gi", "1000m"
)
