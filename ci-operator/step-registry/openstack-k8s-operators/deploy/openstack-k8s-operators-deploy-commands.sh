#!/usr/bin/env bash

set -ex

OPENSTACK_OPERATOR="openstack-operator"

# We don't want to use OpenShift-CI build cluster namespace
unset NAMESPACE

# PR SHA
PR_SHA=$(echo ${JOB_SPEC} | jq -r '.refs.pulls[0].sha')

export IMAGE_TAG_BASE=${REGISTRY}/${ORGANIZATION}/${OPENSTACK_OPERATOR}
export OPENSTACK_OPERATOR_INDEX=${IMAGE_TAG_BASE}-index:${PR_SHA}

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
sleep 240
# Deploy openstack service
make openstack_deploy
sleep 600
# Get all resources
oc get all

# Create clouds.yaml file to be used in further tests.
mkdir -p ~/.config/openstack
cat > ~/.config/openstack/clouds.yaml << EOF
$(oc get cm openstack-config -n openstack -o json | jq -r '.data["clouds.yaml"]')
EOF
export OS_CLOUD=default
KEYSTONE_SECRET_NAME=$(oc get keystoneapi keystone -o json | jq -r .spec.secret)
KEYSTONE_PASSWD_SELECT=$(oc get keystoneapi keystone -o json | jq -r .spec.passwordSelectors.admin)
OS_PASSWORD=$(oc get secret "${KEYSTONE_SECRET_NAME}" -o json | jq -r .data.${KEYSTONE_PASSWD_SELECT} | base64 -d)
export OS_PASSWORD

# Post tests for mariadb-operator
# Check to confirm they we can login into mariadb container and show databases.
MARIADB_SECRET_NAME=$(oc get mariadb openstack -o json | jq -r .spec.secret)
MARIADB_PASSWD=$(oc get secret ${MARIADB_SECRET_NAME} -o json | jq -r .data.DbRootPassword | base64 -d)
oc exec -it  pod/mariadb-openstack -- mysql -uroot -p${MARIADB_PASSWD} -e "show databases;"

# Post tests for keystone-operator
# Check to confirm you can issue a token.
openstack token issue
