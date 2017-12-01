#!/usr/bin/env groovy
@Library("release-library@master")
import com.redhat.openshift.PipelineImageTestStep

import static com.redhat.openshift.BuildPipelineConfiguration.TEST_BINARIES_TAG

testPipeline([new PipelineImageTestStep(
  tag: TEST_BINARIES_TAG,
  ram: "6Gi",
  cpu: "2500m",
  env: [
    JUNIT_REPORT        : "true",
    OPENSHIFT_SKIP_BUILD: "true",
    SKIP_TEARDOWN       : "1",
    DOCKER_HOST         : "fake://"
  ],
  commands: [
    "make test-tools test-integration"
  ]
)])