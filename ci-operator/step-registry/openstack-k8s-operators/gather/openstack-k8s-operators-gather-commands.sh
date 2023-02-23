#!/usr/bin/env bash

set -ex

# We don't want to use OpenShift-CI build cluster namespace
unset NAMESPACE

oc project openstack

oc logs ceph

oc get OpenStackControlPlane openstack -o json

oc get all

oc get -o yaml MariaDB,RabbitMQCluster,KeystoneAPI,PlacementAPI,Glance,Cinder,NeutronAPI,Nova

oc get pods -n openstack --show-labels | grep -i '.*control\-plane\=.*controller\-manager.*' | awk '{print $1}' | xargs -n1 oc logs

# Capture logs from service containers if container is not in Running or Completed state
oc get pods -n openstack --no-headers | egrep -iv controller | egrep -iv 'Running|Completed' | awk '{print $1}' | xargs -n1 -I {} sh -c 'echo "Logs for pod: {}"; oc describe pod {}; oc logs --all-containers=true {}'
