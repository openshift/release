#!/usr/bin/env bash

set -ex

#export OPENSTACK_OPERATOR_INDEX=`${SHARED_DIR}/OPENSTACK_OPERATOR_INDEX`
export OS_REGISTRY=quay.io
export OS_REPO=dviroel
export OPENSTACK_OPERATOR=openstack-operator
export SHA=`echo $JOB_SPEC | jq  -r '.refs.pulls[0].sha'`
export IMAGE_TAG_BASE=${OS_REGISTRY}/${OS_REPO}/${OPENSTACK_OPERATOR}
export OPENSTACK_OPERATOR_INDEX=${IMAGE_TAG_BASE}-index:${SHA}

# Avoid using build cluster namespace
unset NAMESPACE

if [ ! -d "${HOME}/install_yamls" ]; then
  cd ${HOME}
  git clone https://github.com/openstack-k8s-operators/install_yamls.git
fi

cd ${HOME}/install_yamls
# Create/enable openstack namespace
make namespace
# Creates storage
make crc_storage
# Deploy openstack operator
make openstack OPENSTACK_IMG=${OPENSTACK_OPERATOR_INDEX}
sleep 120
# Deploy openstack service
make openstack_deploy
sleep 180
# Get all resources
oc get all
# Show mariadb databases
oc exec -it  pod/mariadb-openstack -- mysql -uroot -p12345678 -e "show databases;"