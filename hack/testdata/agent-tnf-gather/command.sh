#!/usr/bin/env bash
set -euo pipefail
command_name=${0##*/}
printf '%s %s\n' "${command_name}" "$*" >> "${FIXTURE_ROOT}/calls"
case "${command_name}" in
  timeout)
    duration=''
    while (( $# )); do
      case "$1" in
        -s) shift 2 ;;
        --*) shift ;;
        [0-9]*[sm]) duration=$1; shift ;;
        *) break ;;
      esac
    done
    if [[ "${REAL_TIMEOUT:-false}" == true && ( ( "$1" == ssh && ( "${duration}" == 10m || "${duration}" == 15m ) ) || ( "$1" == scp && "${duration}" == 45s && "$*" == *agent-gather\** ) ) ]]; then
      exec /usr/bin/timeout --kill-after=1s 1s "$@"
    fi
    exec "$@"
    ;;
  ssh)
    while [[ "$1" == -o ]]; do shift 2; done
    address=$1
    shift
    if [[ "${address}" == root@* && "$1" == bash ]]; then
      script=$(cat)
      script=${script//\/tmp\//${FIXTURE_ROOT}/remote/tmp/}
      script=${script//\/root\/dev-scripts/${FIXTURE_ROOT}/remote/dev-scripts}
      printf '%s\n' "${script}" >> "${FIXTURE_ROOT}/rendered.sh"
      [[ "${REMOTE_RC:-0}" == 0 ]] || exit "${REMOTE_RC}"
      if [[ "${COLLECTION_SLEEP:-false}" == true && "${script}" == *AGENT_MODE=* ]]; then /usr/bin/sleep 3; fi
      cd "${FIXTURE_ROOT}/remote"
      exec bash -s <<< "${script}"
    elif [[ "${address}" == root@* && "$1" == tar ]]; then
      exec /usr/bin/tar -czf - --transform='s?^dev-scripts?root/dev-scripts?' -C "${FIXTURE_ROOT}/remote" dev-scripts/logs
    fi
    [[ "${address}" != "core@${UNREACHABLE:-none}" ]] || exit 255
    if [[ "$*" == *'command -v agent-gather'* ]]; then exit "${COLLECTOR_RC:-0}"; fi
    if [[ "$*" == *'test -f'* || "$*" == *'container exists etcd'* ]]; then exit 1; fi
    echo 'synthetic journal diagnostic'
    ;;
  scp)
    [[ "${SCP_RC:-0}" == 0 ]] || exit "${SCP_RC}"
    if [[ "${HANG_AGENT_PATTERN:-false}" == true && "$*" == *agent-gather\** ]]; then /usr/bin/sleep 3; fi
    while [[ "$1" == -o ]]; do shift 2; done
    source_path=${1#*:}
    destination=${!#}
    [[ "$1" == root@* ]] || exit 1
    source_path=${source_path/#\/tmp\//${FIXTURE_ROOT}/remote/tmp/}
    source_path=${source_path//\/root\/dev-scripts/${FIXTURE_ROOT}/remote/dev-scripts}
    found=false
    shopt -s nullglob
    for file in ${source_path}; do cp "${file}" "${destination}"; found=true; done
    "${found}"
    ;;
  make)
    [[ "${MAKE_SLEEP:-false}" != true ]] || /usr/bin/sleep 3
    exit "${MAKE_RC:-0}"
    ;;
  oc) exit 1 ;;
  sos) exit 0 ;;
  podman) exit 1 ;;
  sudo) exec "$@" ;;
  virsh) echo synthetic-DHCP ;;
  xmllint) if [[ "$*" == *master-1* ]]; then echo 192.168.111.21; else echo 192.168.111.20; fi ;;
  tar)
    if [[ "$*" == *'-xzf -'* ]]; then exec /usr/bin/tar "$@"; fi
    target=''
    for argument in "$@"; do [[ "${argument}" != *.tar* ]] || target=${argument}; done
    [[ -n "${target}" ]] || exit 0
    mkdir -p "$(dirname "${target}")"
    exec /usr/bin/tar -czf "${target}" --files-from /dev/null
    ;;
esac
