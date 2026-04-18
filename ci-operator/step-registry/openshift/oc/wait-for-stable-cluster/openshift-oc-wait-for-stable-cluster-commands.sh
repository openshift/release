#!/bin/bash
set -euo pipefail

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

oc adm wait-for-stable-cluster --minimum-stable-period="${MINIMUM_STABLE_PERIOD}" --timeout="${TIMEOUT}"
