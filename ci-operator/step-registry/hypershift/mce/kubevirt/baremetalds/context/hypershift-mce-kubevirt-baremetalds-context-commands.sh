#!/bin/bash

set -euo pipefail

role="${OFCIR_CONTEXT_ROLE:?OFCIR_CONTEXT_ROLE is required}"
action="${OFCIR_CONTEXT_ACTION:?OFCIR_CONTEXT_ACTION is required}"
case "${role}" in
  source|target) ;;
  *) echo "Unsupported OFCIR context role" >&2; exit 1 ;;
esac
case "${action}" in
  select|save|activate) ;;
  *) echo "Unsupported OFCIR context action" >&2; exit 1 ;;
esac

context_root="${SHARED_DIR}/ofcir-contexts"
mkdir -p "${context_root}"
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
  local directory="${context_root}/${active}"
  mkdir -p "${directory}"
  for file in "${files[@]}"; do
    if [[ -f "${SHARED_DIR}/${file}" ]]; then
      cp -p "${SHARED_DIR}/${file}" "${directory}/${file}"
    fi
  done
  if [[ -s "${directory}/kubeconfig" ]]; then
    cp -p "${directory}/kubeconfig" "${SHARED_DIR}/management_cluster_kubeconfig_${active}"
  fi
  if [[ -s "${directory}/server-ip" ]]; then
    cp -p "${directory}/server-ip" "${SHARED_DIR}/ofcir-server-ip_${active}"
  fi
}

if [[ "${action}" == select ]]; then
  printf '%s' "${role}" > "${SHARED_DIR}/ofcir-role"
  exit 0
fi

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
  if [[ -f "${context_root}/${role}/${file}" ]]; then
    cp -p "${context_root}/${role}/${file}" "${SHARED_DIR}/${file}"
  fi
done
printf '%s' "${role}" > "${SHARED_DIR}/ofcir-role"
