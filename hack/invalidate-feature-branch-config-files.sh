#!/usr/bin/env bash

set -euo pipefail

ERROR=""
CHECKED_DIR=""
while read -r file;
do
  [[ ! -f "${file}" ]] && echo "skipped deleted ${file}" && continue
  [[ ! "${file}" =~ ^ci-operator/config/.+.yaml ]] && echo "skipped non-configuration ${file}" && continue
  echo "checking ${file} ..."
  dir="$(dirname "${file}")"
  [[ "${dir}" == "${CHECKED_DIR}" ]] && echo "skipped a checked dir ${dir}" && continue
  CHECKED_DIR="${dir}"
  for target in "${dir}"/*.yaml
  do
    base_name=$(basename "${target}")
    file_name="${base_name%.*}"
    for subling in "${dir}"/*.yaml
    do
      subling_base_name=$(basename "${subling}")
      subling_file_name="${subling_base_name%.*}"
      if [[ "${subling_file_name}" == "${file_name}"-* ]]
      then
        >&2 echo "ERROR: The file ${base_name} has a ci-operator's configuration file ${subling} for its feature branch."
        ERROR=1
      fi
    done
  done
done < <(git --no-pager show --name-only --pretty="" | sort)

if [[ "${ERROR}" -eq 0 ]]
then
  echo "INFO: Found no ci-operator's configuration files for feature branches."
else
  exit 1
fi
