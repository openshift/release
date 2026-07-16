#!/bin/bash

set -euo pipefail

echo "************ Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

function pr_debug_mode_waiting {

  echo "################################################################################"
  echo "# Using pull request ${PULL_NUMBER}. Entering in the debug mode waiting..."
  echo "################################################################################"

  TZ=UTC
  END_TIME=$(date -d "${TIMEOUT}" +%s)
  debug_done=/tmp/debug.done
  keep_debugging=/tmp/keep.debugging

  while sleep 1m; do

    test -f "${debug_done}" && break
    echo
    echo "-------------------------------------------------------------------"
    echo "'${debug_done}' not found. Debugging can continue... "
    now=$(date +%s)
    if [ "${END_TIME}" -lt "${now}" ] ; then
      if [ -f "${keep_debugging}" ]; then
        echo "To quit debugging, run the following command from the POD Terminal:"
        echo "$ rm -f ${keep_debugging}"
        continue
      else
        echo "Time out reached. Exiting by timeout..."
        break
      fi
    else
      echo "Now:     $(date -d "@${now}")"
      echo "Timeout: $(date -d "@${END_TIME}")"
    fi
    echo "[Note]:"
    echo "- To exit from debug mode before the timeout is reached,"
    echo "  run the following command from the POD Terminal: $ touch ${debug_done}"
    echo "- To keep debugging after the timeout is reached,"
    echo "  run the following command from the POD Terminal: $ touch ${keep_debugging}"

  done

  echo
  echo "Exiting from Pull Request debug mode..."
}

if [ "${PR_ONLY}" == "false" ] || [ -n "${PULL_NUMBER:-}" ]; then
  pr_debug_mode_waiting
fi
