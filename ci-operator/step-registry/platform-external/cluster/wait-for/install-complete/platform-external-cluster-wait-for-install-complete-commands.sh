#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source "${SHARED_DIR}/init-fn.sh" || true

# Set up the traps
trap collect_bootstrap_error_handler TERM INT HUP
trap collect_bootstrap_error_handler EXIT

make_install_dir

log "Checking and waiting for install-complete"
OK_COUNT=0
OK_LIMIT=5
FAIL_COUNT=0
FAIL_LIMIT=10
while true; do
  if [[ $OK_COUNT -ge $OK_LIMIT ]];
  then
    break;
  fi
  if openshift-install --dir=${INSTALL_DIR} wait-for install-complete 2>&1 | grep --line-buffered -v password; then
    OK_COUNT=$(( OK_COUNT + 1 ))
    log "\ninstall-complete OK [$OK_COUNT/$OK_LIMIT]\n"
    sleep 5
    continue
  fi
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  log "install-complete FAIL [${FAIL_COUNT}/$FAIL_LIMIT], waiting 15s..."
  if [[ $FAIL_COUNT -ge $FAIL_LIMIT ]];
  then
    log "TIMEOUT waiting for install-complete\n"
    break;
  fi
  sleep 15
done

cp -vf ${INSTALL_DIR}/auth/kubeconfig $SHARED_DIR/kubeconfig 

log "Install Completed!"

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"
