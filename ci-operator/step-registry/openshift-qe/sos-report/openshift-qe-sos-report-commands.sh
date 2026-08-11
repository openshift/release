#!/bin/bash

set -euo pipefail
shopt -s inherit_errexit

# shellcheck disable=SC1091
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

SOS_REPORT_NODE_SELECTOR="${SOS_REPORT_NODE_SELECTOR:-}"
SOS_REPORT_CONCURRENCY="${SOS_REPORT_CONCURRENCY:-6}"
OUT_DIR="${ARTIFACT_DIR}/sos-reports"
mkdir -p "${OUT_DIR}"

NODE_ARGS=()
if [[ -n "${SOS_REPORT_NODE_SELECTOR}" ]]; then
  NODE_ARGS+=("-l" "${SOS_REPORT_NODE_SELECTOR}")
fi

mapfile -t NODES < <(oc get nodes "${NODE_ARGS[@]}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

if [[ ${#NODES[@]} -eq 0 ]]; then
  echo "No nodes matched selector '${SOS_REPORT_NODE_SELECTOR}'; nothing to collect"
  exit 0
fi

echo "Collecting sos reports from ${#NODES[@]} node(s): ${NODES[*]}"

collect_sos() {
  local node="$1"
  local outdir="${OUT_DIR}/${node}"
  mkdir -p "${outdir}"

  echo "[${node}] generating sos report"
  if ! oc debug "node/${node}" -- chroot /host sos report --batch --tmp-dir /var/tmp \
      -k podman.all=on -k podman.logs=on \
      > "${outdir}/collect.log" 2>&1; then
    echo "[${node}] sos report command failed, see collect.log"
    return 0
  fi

  local remote_path
  remote_path=$(oc debug "node/${node}" -- chroot /host sh -c \
      'ls -t /var/tmp/sosreport-*.tar.xz 2>/dev/null | head -n1' | tr -d '\r')
  if [[ -z "${remote_path}" ]]; then
    echo "[${node}] no sos report archive found after collection" >> "${outdir}/collect.log"
    return 0
  fi

  echo "[${node}] copying $(basename "${remote_path}") to artifacts"
  if ! oc debug "node/${node}" -- chroot /host cat "${remote_path}" \
      > "${outdir}/$(basename "${remote_path}")"; then
    echo "[${node}] failed to copy sos report archive" >> "${outdir}/collect.log"
    rm -f "${outdir}/$(basename "${remote_path}")"
  fi

  oc debug "node/${node}" -- chroot /host rm -f "${remote_path}" > /dev/null 2>&1 || true
}
export -f collect_sos
export OUT_DIR

printf '%s\n' "${NODES[@]}" | xargs -P "${SOS_REPORT_CONCURRENCY}" -I{} bash -c 'collect_sos "$@"' _ {}

echo "sos report collection complete; see ${OUT_DIR}"
