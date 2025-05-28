#!/usr/bin/env bash

set -ex
DEFAULT_ORG="openstack-k8s-operators"
DEFAULT_REGISTRY="quay.io"
OPENSTACK_OPERATOR="openstack-operator"
OPENSTACK_OPERATOR_TAG=${OPENSTACK_OPERATOR_TAG:="latest"}
BASE_DIR=${HOME:-"/alabama"}
NS_SERVICES=${NS_SERVICES:-"openstack"}
export CEPH_HOSTNETWORK=${CEPH_HOSTNETWORK:-"true"}
export CEPH_DATASIZE=${CEPH_DATASIZE:="8Gi"}
export CEPH_TIMEOUT=${CEPH_TIMEOUT:="90"}

# We don't want to use OpenShift-CI build cluster namespace
unset NAMESPACE

# Check org and project from job's spec
REF_REPO=$(echo ${JOB_SPEC} | jq -r '.refs.repo')
REF_ORG=$(echo ${JOB_SPEC} | jq -r '.refs.org')
REF_BRANCH=$(echo ${JOB_SPEC} | jq -r '.refs.base_ref')
# Prow build id
PROW_BUILD=$(echo ${JOB_SPEC} | jq -r '.buildid')
# PR SHA
PR_SHA=$(echo ${JOB_SPEC} | jq -r '.refs.pulls[0].sha')
# Build tag
BUILD_TAG="${PR_SHA:0:20}-${PROW_BUILD}"

# Fails if step is not being used on openstack-k8s-operators repos
# Gets base repo name
BASE_OP=${REF_REPO}
if [[ "$REF_ORG" != "$DEFAULT_ORG" ]]; then
    echo "Not a ${DEFAULT_ORG} job. Checking if isn't a rehearsal job..."
    EXTRA_REF_REPO=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].repo')
    EXTRA_REF_ORG=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].org')
    REF_BRANCH=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].base_ref')
    if [[ "$EXTRA_REF_ORG" != "$DEFAULT_ORG" ]]; then
      echo "Failing since this step supports only ${DEFAULT_ORG} changes."
      exit 1
    fi
    BASE_OP=${EXTRA_REF_REPO}
fi
SERVICE_NAME=$(echo "${BASE_OP^^}" | sed 's/\(.*\)-OPERATOR/\1/'| sed 's/-/\_/g')
# sets default branch for install_yamls
export OPENSTACK_K8S_BRANCH=${REF_BRANCH}

# Copy base operator code to home directory
cp -r /go/src/github.com/${DEFAULT_ORG}/${BASE_OP}/ ${BASE_DIR}

# custom per project ENV variables
# shellcheck source=/dev/null
if [ -f /go/src/github.com/${DEFAULT_ORG}/${BASE_OP}/.prow_ci.env ]; then
  source /go/src/github.com/${DEFAULT_ORG}/${BASE_OP}/.prow_ci.env
fi

if [[ "$SERVICE_NAME" == "INSTALL_YAMLS" ]]; then
  # when testing install_yamls patch, we can skip build process and
  #  validate using latest openstack-operator tag
  export IMAGE_TAG_BASE=${DEFAULT_REGISTRY}/${DEFAULT_ORG}/${OPENSTACK_OPERATOR}
  export OPENSTACK_OPERATOR_INDEX=${IMAGE_TAG_BASE}-index:${OPENSTACK_OPERATOR_TAG}
else
  export IMAGE_TAG_BASE=${PULL_REGISTRY}/${PULL_ORGANIZATION}/${OPENSTACK_OPERATOR}
  export OPENSTACK_OPERATOR_INDEX=${IMAGE_TAG_BASE}-index:${BUILD_TAG}
fi

if [ ! -d "${BASE_DIR}/install_yamls" ]; then
  cd ${BASE_DIR}
  git clone https://github.com/openstack-k8s-operators/install_yamls.git -b ${REF_BRANCH}
fi

cd ${BASE_DIR}/install_yamls
# set slow etcd profile
make set_slower_etcd_profile
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

# Get default env values from Makefile
DBSERVICE=$(make --eval $'var:\n\t@echo $(DBSERVICE)' NETWORK_ISOLATION=false var)
DBSERVICE_CONTAINER=$(make --eval $'var:\n\t@echo $(DBSERVICE_CONTAINER)' NETWORK_ISOLATION=false var)
OPENSTACK_CTLPLANE=$(make --eval $'var:\n\t@echo $(OPENSTACK_CTLPLANE)' NETWORK_ISOLATION=false var)
OPENSTACK_CTLPLANE_FILE=$(basename $OPENSTACK_CTLPLANE)
export INSTALL_NNCP=false
export INSTALL_NMSTATE=false

# Deploy openstack operator
make openstack_wait OPENSTACK_IMG=${OPENSTACK_OPERATOR_INDEX} NETWORK_ISOLATION=false

# Wait until OLM installs openstack CRDs
n=0
retries=30
until [ "$n" -ge "$retries" ]; do
  oc get crd | grep openstack.org && break
    n=$((n+1))
    sleep 10
done

# if the new initialization resource exists install it
# this will also wait for operators to deploy
if oc get crd openstacks.operator.openstack.org &> /dev/null; then
  make openstack_init
fi

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

# Export OPENSTACK_CR if testing openstack-operator changes
if [[ "$SERVICE_NAME" == "OPENSTACK" ]]; then
  export ${SERVICE_NAME}_CR=/go/src/github.com/${DEFAULT_ORG}/${OPENSTACK_OPERATOR}/${OPENSTACK_CTLPLANE}
fi

make ceph
sleep 30

# Deploy openstack services with the sample from the PR under test
make openstack_deploy_prep NETWORK_ISOLATION=false

cat <<EOF >${BASE_DIR}/install_yamls/out/openstack/openstack/cr/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- ./$(echo ${OPENSTACK_CTLPLANE_FILE})
namespace: openstack
patches:
- patch: |-
    - op: replace
      path: /spec/secret
      value: osp-secret
    - op: replace
      path: /spec/storageClass
      value: "local-storage"
    - op: add
      path: /spec/extraMounts
      value:
        - name: v1
          region: r1
          extraVol:
          - propagation:
            - Manila
            - Glance
            - volume1
            - CinderBackup
            extraVolType: Ceph
            volumes:
            - name: ceph
              projected:
                sources:
                - secret:
                    name: ceph-conf-files
            mounts:
            - name: ceph
              mountPath: "/etc/ceph"
              readOnly: true
    - op: replace
      path: /spec/cinder/template/cinderVolumes/volume1/replicas
      value: 1
    - op: add
      path: /spec/cinder/template/cinderVolumes/volume1/customServiceConfig
      value: |
            [DEFAULT]
            enabled_backends=ceph
            [ceph]
            volume_backend_name=ceph
            volume_driver=cinder.volume.drivers.rbd.RBDDriver
            rbd_ceph_conf=/etc/ceph/ceph.conf
            rbd_user=openstack
            rbd_pool=volumes
            rbd_flatten_volume_from_snapshot=False
            report_discard_supported=True
            backend_host=hostgroup
            rbd_secret_uuid=FSID
    - op: replace
      path: /spec/cinder/template/cinderBackup/replicas
      value: 1
    - op: add
      path: /spec/cinder/template/cinderBackup/customServiceConfig
      value: |
            [DEFAULT]
            backup_driver = cinder.backup.drivers.ceph.CephBackupDriver
            backup_ceph_pool = backups
            backup_ceph_user = openstack
    - op: add
      path: /spec/glance/template/customServiceConfig
      value: |
            [DEFAULT]
            debug = true
            enabled_backends=default_backend:rbd
            [glance_store]
            default_backend=default_backend
            [default_backend]
            rbd_store_ceph_conf=/etc/ceph/ceph.conf
            rbd_store_user=openstack
            rbd_store_pool=images
            store_description=ceph_glance_store
    - op: replace
      path: /spec/glance/template/glanceAPIs/default/type
      value: split
$(if [[ "${SERVICE_NAME}" == "IRONIC" ]]; then
  cat <<IRONIC_EOF
    - op: add
      path: /spec/ironic/enabled
      value: true
IRONIC_EOF
fi)
$(if [[ "${SERVICE_NAME}" == "MANILA" ]]; then
  cat <<MANILA_EOF
    - op: add
      path: /spec/manila/enabled
      value: true
    - op: add
      path: /spec/manila/template/customServiceConfig
      value: |
            [DEFAULT]
            enabled_share_backends=cephfs
            enabled_share_protocols=cephfs
            [cephfs]
            driver_handles_share_servers=False
            share_backend_name=cephfs
            share_driver=manila.share.drivers.cephfs.driver.CephFSDriver
            cephfs_conf_path=/etc/ceph/ceph.conf
            cephfs_auth_id=openstack
            cephfs_cluster_name=ceph
            cephfs_volume_mode=0755
            cephfs_protocol_helper_type=CEPHFS
MANILA_EOF
fi)
  target:
    kind: OpenStackControlPlane
EOF

FSID=$(oc get secret ceph-conf-files -o json | jq -r '.data."ceph.conf"' | base64 -d | grep fsid | awk 'BEGIN { FS = "=" } ; { print $2 }' | xargs)

sed -i ${BASE_DIR}/install_yamls/out/openstack/openstack/cr/kustomization.yaml -e s/FSID/$FSID/g
cat ${BASE_DIR}/install_yamls/out/openstack/openstack/cr/kustomization.yaml

make input
oc kustomize ${BASE_DIR}/install_yamls/out/openstack/openstack/cr/ | oc apply -f -
sleep 60

# Waiting for Openstack CR to be ready
oc kustomize ${BASE_DIR}/install_yamls/out/openstack/openstack/cr/ | oc wait --for condition=Ready --timeout="${TIMEOUT_SERVICES_READY}s" -f -

# Basic validations after deploying
oc project "${NS_SERVICES}"

# Create clouds.yaml file to be used in further tests.
mkdir -p ~/.config/openstack
cat > ~/.config/openstack/clouds.yaml << EOF
$(oc get cm openstack-config -o json | jq -r '.data["clouds.yaml"]')
EOF
export OS_CLOUD=default
KEYSTONE_SECRET_NAME=$(oc get keystoneapi -o json | jq -r '.items[0].spec.secret')
KEYSTONE_PASSWD_SELECT=$(oc get keystoneapi -o json | jq -r '.items[0].spec.passwordSelectors.admin')
OS_PASSWORD=$(oc get secret "${KEYSTONE_SECRET_NAME}" -o json | jq -r .data.${KEYSTONE_PASSWD_SELECT} | base64 -d)
export OS_PASSWORD

# Post tests for mariadb-operator
# Check to confirm they we can login into mariadb container and show databases.
MARIADB_SECRET_NAME=$(oc get ${DBSERVICE} -o json | jq -r '.items[0].spec.secret')
MARIADB_PASSWD=$(oc get secret ${MARIADB_SECRET_NAME} -o json | jq -r .data.DbRootPassword | base64 -d)
oc exec -it  pod/${DBSERVICE_CONTAINER} -- mysql -uroot -p${MARIADB_PASSWD} -e "show databases;"

# Post tests for keystone-operator
# Check to confirm you can issue a token.
openstack --insecure token issue

# Dump keystone catalog endpoints
openstack --insecure endpoint list
