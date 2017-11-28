#!/bin/bash

set -eux

git clone https://github.com/openshift/release
cd release
git fetch https://github.com/openshift/release refs/pull/${PULL_NUMBER}/head
git checkout FETCH_HEAD
promtool check rules ./projects/prometheus/prometheus.rules.yaml
