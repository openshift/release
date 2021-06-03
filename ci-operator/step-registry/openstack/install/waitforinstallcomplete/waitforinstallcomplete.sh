#!/usr/bin/env bash
function wait_for_install_complete() {
  echo "Completing UPI setup"
  TF_LOG=debug openshift-install --dir=${ASSETS_DIR} wait-for install-complete --log-level=debug 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
  wait "$!"

  # Password for the cluster gets leaked in the installer logs and hence removing them.
  sed -i 's/password: .*/password: REDACTED"/g' ${ARTIFACT_DIR}/installer/.openshift_install.log
}
wait_for_install_complete