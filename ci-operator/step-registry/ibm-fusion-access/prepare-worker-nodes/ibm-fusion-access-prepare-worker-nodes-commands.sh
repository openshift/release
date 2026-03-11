#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

workerNodes=$(oc get nodes -l node-role.kubernetes.io/worker= --no-headers | awk '{print $1}')

function CreateDirectoryOnNode () {
  typeset node="${1}"; (($#)) && shift
  typeset dir="${1}"; (($#)) && shift

  oc debug -n default "node/${node}" -- chroot /host mkdir -p "${dir}"

  true
}

for node in ${workerNodes}; do
  if ! CreateDirectoryOnNode "${node}" "/var/lib/firmware"; then
    exit 1
  fi
  
  if ! CreateDirectoryOnNode "${node}" "/var/mmfs/etc"; then
    exit 1
  fi
  if ! CreateDirectoryOnNode "${node}" "/var/mmfs/tmp/traces"; then
    exit 1
  fi
  if ! CreateDirectoryOnNode "${node}" "/var/mmfs/pmcollector"; then
    exit 1
  fi
done

true
