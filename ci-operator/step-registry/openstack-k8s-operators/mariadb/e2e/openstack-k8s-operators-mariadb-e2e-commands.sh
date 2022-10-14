#!/usr/bin/env bash

set -ex

#DEBUG
env

# Get install_yamls
cd $HOME
rm -rf install_yamls
git clone https://github.com/openstack-k8s-operators/install_yamls.git
cd $HOME/install_yamls
# Sets namespace to 'openstack'
export NAMESPACE=openstack
# Creates namespace
make namespace
sleep 5
# Creates storage needed for mariadb
make crc_storage
sleep 20
# DEBUG
sleep 7200
# Deploy mariadb operator
make mariadb MARIADB_IMG=${MARIADB_OPERATOR_INDEX}
sleep 160
# Deploy mariadb service
make mariadb_deploy
sleep 120
# Get all resources
oc get all
# Show mariadb databases
oc exec -it  pod/mariadb-openstack -- mysql -uroot -p12345678 -e "show databases;"
sleep 1800
