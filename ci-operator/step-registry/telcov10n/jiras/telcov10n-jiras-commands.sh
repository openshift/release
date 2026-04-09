#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

function gathering_jiras_info {

  echo "************ telcov10n Gathering Jiras info ************"

  if [[ "${JIRAS:="[]"}" == "[]" ]] ; then
    echo
    echo "No related Jiras to watch out"
    echo
    return
  fi

  echo
  echo "Jiras to watch out:"
  echo

  jq -c '.[]' <<< "$(yq -o json <<< ${JIRAS})" | while read -r entry; do
    # Extract the filename and content
    description=$(echo "$entry" | jq -r '.description')
    links=$(echo "$entry" | jq -r '.links')
    pull_requets=$(echo "$entry" | jq -r '.PRs')

     process_jiras "${description}" "${links}" "${pull_requets}"
  done
}

function process_jiras {

  desc=$1 ; shift
  jira_links=$1 ; shift
  prs=$1

  echo "####################################################################################################"
  echo
  echo " -- Description ------------------------------------------------------------------------------------"
  echo
  echo "${desc}"
  echo
  echo " -- JIRAS ------------------------------------------------------------------------------------------"
  echo
  echo "${jira_links}" | jq -r '.[]'
  echo
  echo " -- Related Pull Requests --------------------------------------------------------------------------"
  echo
  echo "${prs}" | jq -r '.[]'
  echo

}

function main {
  gathering_jiras_info
}

main
