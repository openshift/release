#!/bin/bash

set -euo pipefail

docker rm origin-gce || true
docker create --name origin-gce -e STARTUP_SCRIPT_FILE=/usr/local/install/data/startup.sh openshift/gce-cloud-installer:latest $@
docker cp data origin-gce:/usr/local/install
docker cp config.sh origin-gce:/usr/local/install/data/
docker start -a origin-gce

# source data/config.sh
# oc login "https://${MASTER_DNS_NAME}" # has to be through UI
# grant cluster admin to user
# oc apply -f setup/roles.yaml
# set up router certificate
# oc project ci
# oc secrets new origin-gce data -o yaml > setup/secrets.yaml
# oadm policy remove-cluster-role-from-group self-provisioner system:authenticated:oauth
# add self-provisioner to "self-provisioners" group
# change registry DNS name to registry.svc.ci.openshift.org
