#!/bin/bash

MANAGED_REPOS=(
  openshift/cluster-capacity
  openshift/coredns
  openshift/descheduler
  openshift/image-registry
  openshift/kubernetes-autoscaler
  openshift/kubernetes-metrics-server
  openshift/openshift-ansible
  openshift/origin
  openshift/origin-aggregated-logging
  openshift/origin-metrics
  openshift/origin-web-console
  openshift/origin-web-console-server
  openshift/service-catalog
)

function managed_repos() {
  base=$( dirname "${BASH_SOURCE[0]}")
  config="${base}/../../ci-operator/jobs/*.yaml"
  branch=$1
  python "${base}/repos_with_job_labels.py" "${config}" "" "${branch}" "artifacts" | sort
}