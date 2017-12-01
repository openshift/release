#!/usr/bin/env groovy
@Library("release-library@master")
import com.redhat.openshift.PipelineImageTestStep

import static com.redhat.openshift.BuildPipelineConfiguration.TEST_BINARIES_TAG

testPipeline([new PipelineImageTestStep(
  tag: TEST_BINARIES_TAG,
  ram: "10.1Gi",
  cpu: "2500m",
  env: [
    JUNIT_REPORT : "true",
    SKIP_TEARDOWN: "1",
    TEST_KUBE    : "1"
  ],
  commands: [
    "env --unset=KUBERNETES_SERVICE_HOST --unset=KUBERNETES_SERVICE_PORT make test-unit"
  ]
)])