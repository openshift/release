#!/usr/bin/env groovy
@Library("release-library@master")
import com.redhat.openshift.BuildPipelineConfiguration
import com.redhat.openshift.ImageBuildSpecification
import com.redhat.openshift.ImageReference

buildPipeline(new BuildPipelineConfiguration(
  testBinaryBuildCommands: ["tox --notest"],
  rpmBuildCommands: ["tito tag --offline --accept-auto-changelog",
                     "tito build --output=/srv/ --rpm --test --offline --quiet",
                     "createrepo /srv/openshift-ansible/noarch"],
  rpmBuildLocation: "/srv/openshift-ansible/noarch"
))