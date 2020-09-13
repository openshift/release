#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

registry="registry.svc.ci.openshift.org"
namespace="ocp"
repository="release"
#Hard-coded for now
upgrade_version_label="4.6.0-0.ci-2020-09-10-092129"
#upgrade_by_digest="bc601ebdd308f26178c8f03b570e76b0a79c8db01969b082de0fa967ee3ef998"

check_before_upgrade () {
    # Check that all nodes are in a Ready status.
    nodes_health=$(oc get nodes | awk '{print $2}' | awk '!/STATUS/ && !/Ready/')
    if [ ! -z ${nodes_health} ]; then echo "ERROR: One of the nodes is not in a ready state" && exit 1; fi;

    # Verify the current status version is available and there is no upgrade in progress.
    upgrade_in_progress=$(oc get clusterversion | awk '{print $4}' | awk '!/PROGRESSING/ && !/False/')
    if [ ! -z ${upgrade_in_progress} ]; then echo "ERROR: Upgrade in progress" && exit 1; fi;

    # Ensure the cluster is healthy and the upgrade can be performed checking that all operators are available, 
    # none of them should be degraded.
    all_operators_available=$(oc get clusteroperators | awk '{print $3}' | awk '!/AVAILABLE/ && !/True/')
    if [ ! -z ${all_operators_available} ]; then echo "ERROR: One of the operators is unavailable" && exit 1; fi;

    no_updates_in_progress=$(oc get clusteroperators | awk '{print $4}' | awk '!/PROGRESSING/ && !/False/')
    if [ ! -z ${no_updates_in_progress} ]; then echo "ERROR: A cluster version change is in progress" && exit 1; fi;

    no_degraded_operators=$(oc get clusteroperators | awk '{print $5}' | awk '!/DEGRADED/ && !/False/')
    if [ ! -z ${no_degraded_operators} ]; then echo "ERROR: One or more degraded operators." && exit 1; fi;
}

check_before_upgrade

echo "************ baremetalds e2e upgrade command ************"
#echo ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}

current_version=$(oc get clusterversion | awk '{print $2}' | awk '!/VERSION/')
original_version=$current_version
echo "Current cluster version: $current_version"

echo "Updating to version: $upgrade_version_label" 
oc adm upgrade --force --allow-explicit-upgrade --to-image=${registry}/${namespace}/${repository}:${upgrade_version_label}
#oc adm upgrade --force --allow-explicit-upgrade --to-image=${registry}${repository}@sha256:${upgrade_by_digest}

while [ $current_version != $upgrade_version_label ]; do sleep 5; current_version=$(oc get clusterversion | awk '{print $2}' | awk '!/VERSION/'); done

echo "Finished upgrading from version $original_version to version $upgrade_version_label !"