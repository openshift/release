#!/usr/bin/env groovy
@Library("release-library@master")
import com.redhat.openshift.ClusterTestStep
import com.redhat.openshift.PipelineImageTestStep

import static com.redhat.openshift.BuildPipelineConfiguration.TEST_BINARIES_TAG
import static com.redhat.openshift.TestUtilities.GCE_DATA_PATH

testPipeline([new ClusterTestStep(
  step: new PipelineImageTestStep(
    tag: TEST_BINARIES_TAG,
    ram: "4.1Gi",
    cpu: "2500m",
    env: [
      JUNIT_REPORT                  : "true",
      TEST_ONLY                     : "1",
      SKIP_TEARDOWN                 : "1",
      OPENSHIFT_SKIP_BUILD          : "true",
      PARALLEL_NODES                : "25",
      TEST_EXTENDED_SKIP            : "\\[local\\]|should provide DNS for services|should support subPath|should work with TCP \\(when fully idled\\)|should test kubelet managed /etc/hosts file|\\[networking\\]\\[router\\]|\\[Area:Networking\\]\\[Feature:Router\\]|Downward API volume should update annotations on modification|should run a deployment to completion and then scale to zero|Basic StatefulSet functionality Scaling down before scale up is finished should wait until current pod will be running and ready before it will be removed|Probing container should \\*not\\* be restarted with a /healthz http liveness probe",
      TEST_EXTENDED_ARGS            : '-provider=gce -gce-zone=us-central1-a -gce-project=openshift-gce-devel-ci'
    ],
    commands: [
      "make test-extended SUITE=conformance"
    ]
  ))])