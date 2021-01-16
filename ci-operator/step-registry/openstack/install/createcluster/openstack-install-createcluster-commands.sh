#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
export OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME}/${BUILD_ID}
export HOME=/tmp

case "${CLUSTER_TYPE}" in
openstack) export OS_CLIENT_CONFIG_FILE=${CLUSTER_PROFILE_DIR}/clouds.yaml ;;
openstack-vexxhost) export OS_CLIENT_CONFIG_FILE=${CLUSTER_PROFILE_DIR}/clouds.yaml ;;
*) >&2 echo "Unsupported cluster type '${CLUSTER_TYPE}'"
esac

ASSETS_DIR=/tmp/installer
mkdir "${ASSETS_DIR}/"
cp "${SHARED_DIR}/install-config.yaml" "${ASSETS_DIR}/"

mkdir -p ~/.ssh
cp "${SSH_PRIV_KEY_PATH}" ~/.ssh/


if [[ "${USE_ETCD_RAMDISK}" == "true" ]]; then
  TF_LOG=debug openshift-install --dir=${ASSETS_DIR} create ignition-configs --log-level=debug
  python -c \
      'import json, sys; j = json.load(sys.stdin); j[u"systemd"] = {}; j[u"systemd"][u"units"] = [{u"contents": "[Unit]\nDescription=Mount etcd as a ramdisk\nBefore=local-fs.target\n[Mount]\n What=none\nWhere=/var/lib/etcd\nType=tmpfs\nOptions=size=2G\n[Install]\nWantedBy=local-fs.target", u"enabled": True, u"name":u"var-lib-etcd.mount"}]; json.dump(j, sys.stdout)' \
      <${ASSETS_DIR}/master.ign \
      >${ASSETS_DIR}/master.ign.out
  mv ${ASSETS_DIR}/master.ign.out ${ASSETS_DIR}/master.ign
fi


TF_LOG=debug openshift-install --dir=${ASSETS_DIR} create manifests --log-level=debug &
wait "$!"

sed -i '/^  channel:/d' "${ASSETS_DIR}/manifests/cvo-overrides.yaml"


TF_LOG=debug openshift-install --dir="${ASSETS_DIR}" create cluster --log-level=debug 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &

set +e
wait "$!"
ret="$?"
cp "${ASSETS_DIR}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null
set -e

sed '
  s/password: .*/password: REDACTED/;
  s/X-Auth-Token.*/X-Auth-Token REDACTED/;
  s/UserData:.*,/UserData: REDACTED,/;
  ' "${ASSETS_DIR}/.openshift_install.log" > "${ARTIFACT_DIR}/.openshift_install.log"

cp \
    -t "${SHARED_DIR}" \
    "${ASSETS_DIR}/auth/kubeconfig" \
    "${ASSETS_DIR}/auth/kubeadmin-password" \
    "${ASSETS_DIR}/metadata.json"
exit "$ret"