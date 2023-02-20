#!/usr/bin/env bash

set -ex

ORG="openstack-k8s-operators"
OPENSTACK_OPERATOR="openstack-operator"

# We don't want to use OpenShift-CI build cluster namespace
unset NAMESPACE

# Check org and project from job's spec
REF_REPO=$(echo ${JOB_SPEC} | jq -r '.refs.repo')
REF_ORG=$(echo ${JOB_SPEC} | jq -r '.refs.org')
# PR SHA
PR_SHA=$(echo ${JOB_SPEC} | jq -r '.refs.pulls[0].sha')

# Fails if step is not being used on openstack-k8s-operators repos
# Gets base repo name
BASE_OP=${REF_REPO}
if [[ "$REF_ORG" != "$ORG" ]]; then
    echo "Not a ${ORG} job. Checking if isn't a rehearsal job..."
    EXTRA_REF_REPO=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].repo')
    EXTRA_REF_ORG=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].org')
    #EXTRA_REF_BASE_REF=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].base_ref')
    if [[ "$EXTRA_REF_ORG" != "$ORG" ]]; then
      echo "Failing since this step supports only ${ORG} changes."
      exit 1
    fi
    BASE_OP=${EXTRA_REF_REPO}
fi
SERVICE_NAME=$(echo "${BASE_OP^^}" | sed 's/\(.*\)-OPERATOR/\1/'| sed 's/-/\_/g')

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

# Export OPENSTACK_CR if testing openstack-operator changes
if [[ "$SERVICE_NAME" == "OPENSTACK" ]]; then
  export ${SERVICE_NAME}_CR=/go/src/github.com/${ORG}/${OPENSTACK_OPERATOR}/config/samples/core_v1beta1_openstackcontrolplane.yaml
fi

make ceph TIMEOUT=90
sleep 30

# Deploy openstack services with the sample from the PR under test
make openstack_deploy_prep

cat <<EOF >${HOME}/install_yamls/out/openstack/openstack/cr/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- ./core_v1beta1_openstackcontrolplane.yaml
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
  target:
    kind: OpenStackControlPlane
EOF

FSID=$(oc get secret ceph-conf-files -o json | jq -r '.data."ceph.conf"' | base64 -d | grep fsid | awk 'BEGIN { FS = "=" } ; { print $2 }' | xargs)

sed -i ${HOME}/install_yamls/out/openstack/openstack/cr/kustomization.yaml -e s/FSID/$FSID/g
cat ${HOME}/install_yamls/out/openstack/openstack/cr/kustomization.yaml

make input
oc kustomize ${HOME}/install_yamls/out/openstack/openstack/cr/ | oc apply -f -
sleep 60

# Waiting for all services to be ready
oc get OpenStackControlPlane openstack -o json | jq -r '.status.conditions[].type' | \
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
