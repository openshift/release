#!/bin/bash
set -euo pipefail

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

if ! oc adm wait-for-stable-cluster --help &>/dev/null; then
  echo "oc adm wait-for-stable-cluster is not available in this release"
  exit 1
fi

oc adm wait-for-stable-cluster --minimum-stable-period="${MINIMUM_STABLE_PERIOD}" --timeout="${TIMEOUT}"
