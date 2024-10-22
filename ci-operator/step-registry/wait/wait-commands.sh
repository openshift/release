#!/bin/bash

echo "************ Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

function pr_debug_mode_waiting {

  echo "################################################################################"
  echo "# Using pull request ${PULL_NUMBER}. Entering in the debug mode waiting..."
  echo "################################################################################"

  TZ=UTC
  END_TIME=$(date -d "${TIMEOUT}" +%s)
  debug_done=/tmp/debug.done

  while sleep 1m; do

    test -f ${debug_done} && break
    echo
    echo "-------------------------------------------------------------------"
    echo "'${debug_done}' not found. Debugging can continue... "
    now=$(date +%s)
    if [ ${END_TIME} -lt ${now} ] ; then
      echo "Time out reached. Exiting by timeout..."
      break
    else
      echo "Now:     $(date -d @${now})"
      echo "Timeout: $(date -d @${TIMEOUT})"
    fi
    echo "Note: To exit from debug mode before the timeout is reached,"
    echo "just run the following command from the POD Terminal:"
    echo "$ touch ${debug_done}"

  done

  echo
  echo "Exiting from Pull Request debug mode..."
}

if [ "${PR_ONLY}" == "false" ] || [ -n "${PULL_NUMBER:-}" ]; then
  pr_debug_mode_waiting
fi
