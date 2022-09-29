#!/usr/bin/env bash

set -ex

cd $HOME
# Setting up kustomize, needed by install_yamls makefile
mkdir bin
export PATH=$PATH:$HOME/bin
cd $HOME/bin
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"  | bash
cd $HOME
# Get install_yamls
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
# Deploy mariadb operator
make mariadb
sleep 120
# Deploy mariadb service
make mariadb_deploy
sleep 120
# Get all resources
oc get all
# Show mariadb databases
oc exec -it  pod/mariadb-openstack -- mysql -uroot -p12345678 -e "show databases;"
