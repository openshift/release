#!/usr/bin/env bash
function wait_for_bootstrap_complete() {
  signal_oc_bootstrap_started
  echo "Waiting for bootstrap to complete"
  date
  TF_LOG=debug openshift-install --dir=${ASSETS_DIR} wait-for bootstrap-complete --log-level=debug 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
  wait "$!"
}

wait_for_bootstrap_complete

