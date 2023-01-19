#!/usr/bin/env bash

set -ex

# We don't want to use OpenShift-CI build cluster namespace
unset NAMESPACE

oc project openstack

oc get OpenStackControlPlane openstack -o json

oc get all
