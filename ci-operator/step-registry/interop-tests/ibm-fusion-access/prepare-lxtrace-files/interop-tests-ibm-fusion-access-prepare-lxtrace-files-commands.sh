#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

# Purpose: Collect lxtrace logs from worker nodes via oc debug or write placeholder artifacts when logs are absent.
# Inputs: ARTIFACT_DIR, worker nodes with storage role; uses oc debug chroot on each node.
# Non-obvious: Inner bash -c loops copy or create dummy files under lxtrace paths for CI artifacts.

typeset nodesJson=''
nodesJson="$(oc get nodes -l node-role.kubernetes.io/worker= -o json)"
typeset -i workerCount=0
workerCount="$(printf '%s' "${nodesJson}" | jq '.items | length')"

if [[ "${workerCount}" -le 0 ]]; then
  exit 1
fi

typeset node=''
while IFS= read -r node; do
    oc debug -n default node/"${node}" --quiet -- chroot /host bash -eux -o pipefail -c '
    shopt -s inherit_errexit nullglob
    typeset -a lxtraceFiles=(/var/lib/firmware/lxtrace-*)
    if [[ "${#lxtraceFiles[@]}" -gt 0 ]]; then
      for f in "${lxtraceFiles[@]}"; do
        if [[ -f "${f}" ]]; then
          cp "${f}" /var/gpfs/bin/ && chmod +x "/var/gpfs/bin/${f##*/}"
        fi
      done
    else
      typeset kernelVer=""
      kernelVer="$(uname -r)"
      touch /var/lib/firmware/lxtrace-dummy
      touch "/var/gpfs/bin/lxtrace-${kernelVer}"
      chmod +x "/var/gpfs/bin/lxtrace-${kernelVer}"
    fi

    ls -la /var/gpfs/bin/

    true
  ' 2>&1 | sed -e '/Starting pod/d' -e '/Removing debug/d' -e '/To use host/d'
  done < <(printf '%s' "${nodesJson}" | jq -r '.items[].metadata.name')

true
