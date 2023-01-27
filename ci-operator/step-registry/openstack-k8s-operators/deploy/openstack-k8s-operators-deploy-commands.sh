#!/usr/bin/env bash

set -ex

ORG="openstack-k8s-operators"
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
# Sometimes it fails to find container-00 inside debug pod
# TODO: fix issue in install_yamls
n=0
retries=3
while true; do
  make crc_storage && break
  n=$((n+1))
  if (( n >= retries )); then
    echo "Failed to run 'make crc_storage' target. Aborting"
    exit 1
  fi
  sleep 10
done


# Deploy openstack operator
make openstack OPENSTACK_IMG=${OPENSTACK_OPERATOR_INDEX}
# Wait before start checking all deployment status
# Not expecting to fail here, only in next deployment checks
n=0
retries=30
until [ "$n" -ge "$retries" ]; do
  oc get deployment openstack-operator-controller-manager && break
    n=$((n+1))
    sleep 10
done

# Check if all deployments are available
INSTALLED_CSV=$(oc get subscription openstack-operator -o jsonpath='{.status.installedCSV}')
oc get csv ${INSTALLED_CSV} -o jsonpath='{.spec.install.spec.deployments[*].name}' | \
timeout ${TIMEOUT_OPERATORS_AVAILABLE} xargs -I {} -d ' ' \
sh -c 'oc wait --for=condition=Available deployment {} --timeout=-1s'

# Deploy openstack services with the sample from the PR under test
OPENSTACK_CR=/go/src/github.com/${ORG}/${OPENSTACK_OPERATOR}/config/samples/core_v1beta1_openstackcontrolplane.yaml make openstack_deploy
sleep 60

# Waiting for all services to be ready
# TODO(dviroel): Add cinder back to status check once ceph backend is functional
oc get OpenStackControlPlane openstack -o json | \
jq -r '.status.conditions[] | select(.type | test("^OpenStackControlPlane(?!Cinder)")).type' | \
timeout ${TIMEOUT_SERVICES_READY} xargs -d '\n' -I {} sh -c 'echo testing condition={}; oc wait openstackcontrolplane.core.openstack.org/openstack --for=condition={} --timeout=-1s'

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
