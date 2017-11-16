#!/usr/bin/env groovy

library "github.com/stevekuznetsov/release-library@skuznets/build-pipeline"

buildPipeline(
  "build",
  cloneStep("openshift-ansible:test-base"),
  [buildStep(
    "build-rpms",
    "src", "rpms",
    "RUN umask 0002 && mkdir -p /srv/openshift-ansible/noarch && tito tag --offline --accept-auto-changelog && tito build --output=/srv/ --rpm --test --offline --quiet && createrepo /srv/openshift-ansible/noarch"
  )]
)