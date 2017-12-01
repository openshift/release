#!/usr/bin/env groovy
@Library("release-library@master")
import com.redhat.openshift.BuildPipelineConfiguration
import com.redhat.openshift.ImageBuildSpecification
import com.redhat.openshift.ImageReference

buildPipeline(new BuildPipelineConfiguration(
  testBaseTag: "golang-1.9",
  binaryBuildCommands: ["make build"],
  testBinaryBuildCommands: ["OS_GOFLAGS='-race' make build"],
  rpmBuildCommands: ["make build-rpms"],
  baseRPMImages: [new ImageReference(
    namespace: "stable",
    name: "origin-base",
    tag: "latest"
  )],
  images: [new ImageBuildSpecification(
    from: "origin-base",
    to: "origin-docker-registry",
    contextDir: "images/dockerregistry/"
  )]
))