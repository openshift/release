#!/usr/bin/env groovy
@Library("release-library@master")
import com.redhat.openshift.PipelineImageTestStep

import static com.redhat.openshift.BuildPipelineConfiguration.TEST_BINARIES_TAG

testPipeline([new PipelineImageTestStep(
  tag: TEST_BINARIES_TAG,
  ram: "7.1Gi",
  cpu: "2500m",
  env: [
    JUNIT_REPORT : "true",
    SKIP_TEARDOWN: "1"
  ],
  commands: [
    "make test-cmd"
  ]
)])