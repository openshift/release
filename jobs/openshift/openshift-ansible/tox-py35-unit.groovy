#!/usr/bin/env groovy
@Library("release-library@master")
import com.redhat.openshift.PipelineImageTestStep

import static com.redhat.openshift.BuildPipelineConfiguration.TEST_BINARIES_TAG

testPipeline([new PipelineImageTestStep(
  tag: TEST_BINARIES_TAG,
  commands: ["./.tox/py35-unit/bin/pytest"]
)])