#!/usr/bin/env bash

set -ex

# We don't want to use OpenShift-CI build cluster namespace
unset NAMESPACE

oc project openstack

oc get OpenStackControlPlane openstack -o json

oc get all

oc get -o yaml MariaDB,RabbitMQCluster,KeystoneAPI,PlacementAPI,Glance,Cinder,NeutronAPI,Nova

oc get pods --selector control-plane=controller-manager -o name | xargs -n1 oc logs

