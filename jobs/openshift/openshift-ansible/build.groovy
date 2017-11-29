#!/usr/bin/env groovy

library "github.com/openshift/release-library@master"

buildPipeline(
  "build",
  cloneStep("openshift-ansible:test-base"),
  [buildStep(
    "build-tox",
    "src", "tox",
    "RUN umask 0002 && /usr/bin/tox --notest"
  ),buildStep(
    "build-rpms",
    "src", "rpms",
    "RUN umask 0002 && mkdir -p /srv/openshift-ansible/noarch && tito tag --offline --accept-auto-changelog && tito build --output=/srv/ --rpm --test --offline --quiet && createrepo /srv/openshift-ansible/noarch"
  )]
)
