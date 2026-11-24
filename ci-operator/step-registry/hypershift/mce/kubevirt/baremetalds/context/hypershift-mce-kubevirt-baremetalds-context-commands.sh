#!/bin/bash

set -euo pipefail
shopt -s nullglob

role="${OFCIR_CONTEXT_ROLE:?OFCIR_CONTEXT_ROLE is required}"
action="${OFCIR_CONTEXT_ACTION:?OFCIR_CONTEXT_ACTION is required}"
case "${role}" in
  source|target) ;;
  *) echo "Unsupported OFCIR context role" >&2; exit 1 ;;
esac
case "${action}" in
  save|activate) ;;
  *) echo "Unsupported OFCIR context action" >&2; exit 1 ;;
esac

files=(
  cir server-ip server-sshport packet-conf.sh kubeconfig kubeadmin-password
  install-status.txt ds-vars.conf console.url proxy-conf.sh
  dev-scripts-additional-config cir-extra cir-nodes bm.json
  devscripts-logs-collected
  unset-proxy.sh must-gather-image.sh custom-links.txt install-duration.log
  install-post-check-status.txt install-pre-config-status.txt
  install_infrastructure_failure.log
)

save_active() {
  local active="${1}"
  local manifest
  # ci-operator only passes top-level files to subsequent steps.
  local prefix="${SHARED_DIR}/ofcir-${active}-"
  for file in "${files[@]}"; do
    if [[ -f "${SHARED_DIR}/${file}" ]]; then
      cp -p "${SHARED_DIR}/${file}" "${prefix}${file}"
    fi
  done
  rm -f -- "${prefix}"manifest_*.{yaml,yml}
  for manifest in "${SHARED_DIR}"/manifest_*.{yaml,yml}; do
    cp -p -- "${manifest}" "${prefix}${manifest##*/}"
  done
  if [[ -s "${prefix}kubeconfig" ]]; then
    cp -p "${prefix}kubeconfig" "${SHARED_DIR}/management_cluster_kubeconfig_${active}"
  fi
}

active=""
if [[ -f "${SHARED_DIR}/ofcir-role" ]]; then
  active="$(<"${SHARED_DIR}/ofcir-role")"
fi
if [[ "${active}" == source || "${active}" == target ]]; then
  save_active "${active}"
fi

if [[ "${action}" == save ]]; then
  [[ "${active}" == "${role}" ]] || { echo "Wrong active OFCIR role" >&2; exit 1; }
  exit 0
fi

if [[ "${active}" == "${role}" ]]; then
  exit 0
fi

for file in "${files[@]}"; do
  rm -f "${SHARED_DIR}/${file}"
  if [[ -f "${SHARED_DIR}/ofcir-${role}-${file}" ]]; then
    cp -p "${SHARED_DIR}/ofcir-${role}-${file}" "${SHARED_DIR}/${file}"
  fi
done
prefix="${SHARED_DIR}/ofcir-${role}-"
rm -f -- "${SHARED_DIR}"/manifest_*.{yaml,yml}
for manifest in "${prefix}"manifest_*.{yaml,yml}; do
  cp -p -- "${manifest}" "${SHARED_DIR}/${manifest#"${prefix}"}"
done
printf '%s' "${role}" > "${SHARED_DIR}/ofcir-role"
