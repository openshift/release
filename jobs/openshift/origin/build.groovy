#!/usr/bin/env groovy
@Library("release-library@master")
import com.redhat.openshift.BuildPipelineConfiguration
import com.redhat.openshift.CacheStep
import com.redhat.openshift.CloneStep
import com.redhat.openshift.ImageBuildSpecification
import com.redhat.openshift.ImageReference
import com.redhat.openshift.PipelineImageReference

import static com.redhat.openshift.BuildPipelineConfiguration.TEST_BINARIES_TAG

buildPipeline(new BuildPipelineConfiguration(
  testBaseTag: "golang-1.9",
  binaryBuildCommands: [
    "OS_ONLY_BUILD_PLATFORMS='linux/amd64' OS_BUILD_RELEASE_ARCHIVES='n' make build-cross",
    "OS_ONLY_BUILD_PLATFORMS='linux/amd64' OS_BUILD_RELEASE_ARCHIVES='n' make build WHAT=tools/gendocs",
    "OS_ONLY_BUILD_PLATFORMS='linux/amd64' OS_BUILD_RELEASE_ARCHIVES='n' make build WHAT=tools/genman"
  ],
  rpmBuildCommands: [
    "OS_ONLY_BUILD_PLATFORMS='linux/amd64' GOPATH='' cmd/service-catalog/go/src/github.com/kubernetes-incubator/service-catalog/hack/build-cross.sh",
    "OS_ONLY_BUILD_PLATFORMS='linux/amd64' GOPATH='' cmd/cluster-capacity/go/src/github.com/kubernetes-incubator/cluster-capacity/hack/build-cross.sh",
    "touch .local",
    "OS_ONLY_BUILD_PLATFORMS='linux/amd64' make build-rpms"
  ],
  /**
   * we need to have a custom base image for tests
   * as we need to cache compiles with and without
   * the race detector on and we can't do that in
   * one image
   */
  rawSteps: [new CloneStep(
    from: new ImageReference(
      namespace: "stable",
      name: "origin-test-base",
      tag: "golang-1.9-race",
    ),
    to: new PipelineImageReference(
      tag: "src-race"
    )
  ), new CacheStep(
    from: new PipelineImageReference(
      tag: "src-race"
    ),
    to: new PipelineImageReference(
      tag: TEST_BINARIES_TAG,
    ),
    commands: ["OS_GOFLAGS='-race' make build build-tests"]
  )],
  baseRPMImages: [new ImageReference(
    namespace: "stable",
    name: "centos",
    tag: "7"
  )],
  images: [new ImageBuildSpecification(
    from: "centos",
    to: "origin-base",
    contextDir: "images/base/"
  ), new ImageBuildSpecification(
    from: "centos",
    to: "origin-pod",
    contextDir: "images/pod/"
  ), new ImageBuildSpecification(
    from: "centos",
    to: "origin-cluster-capacity",
    contextDir: "images/cluster-capacity/"
  ), new ImageBuildSpecification(
    from: "centos",
    to: "origin-template-service-broker",
    contextDir: "images/template-service-broker/"
  ), new ImageBuildSpecification(
    from: "origin-base",
    to: "origin",
    contextDir: "images/origin/"
  ), new ImageBuildSpecification(
    from: "origin-base",
    to: "origin-egress-router",
    contextDir: "images/egress/router/"
  ), new ImageBuildSpecification(
    from: "origin-base",
    to: "origin-egress-http-proxy",
    contextDir: "images/egress/http-proxy/"
  ), new ImageBuildSpecification(
    from: "origin-base",
    to: "origin-federation",
    contextDir: "images/federation/"
  ), new ImageBuildSpecification(
    from: "origin",
    to: "origin-haproxy-router",
    contextDir: "images/router/haproxy"
  ), new ImageBuildSpecification(
    from: "origin",
    to: "origin-keepalived-ipfailover",
    contextDir: "images/ipfailover/keepalived/"
  ), new ImageBuildSpecification(
    from: "origin",
    to: "origin-deployer",
    contextDir: "images/deployer/"
  ), new ImageBuildSpecification(
    from: "origin",
    to: "origin-recycler",
    contextDir: "images/recycler/"
  ), new ImageBuildSpecification(
    from: "origin",
    to: "origin-docker-builder",
    contextDir: "images/builder/docker/docker-builder/"
  ), new ImageBuildSpecification(
    from: "origin",
    to: "origin-sti-builder",
    contextDir: "images/builder/docker/sti-builder/"
  ), new ImageBuildSpecification(
    from: "origin",
    to: "origin-f5-router",
    contextDir: "images/router/f5/"
  ), new ImageBuildSpecification(
    from: "origin",
    to: "node",
    contextDir: "images/node/"
  ), new ImageBuildSpecification(
    from: "node",
    to: "openvswitch",
    contextDir: "images/openvswitch/"
  )]
))