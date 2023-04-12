#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
DEFAULT=$(dirname "${SCRIPT_DIR}")/core-services/image-mirroring/supplemental-ci-images
MAPPING_FOLDER="${1:-${DEFAULT}}"

echo "MAPPING_FOLDER is ${MAPPING_FOLDER}"

ERROR=0

for file in "${MAPPING_FOLDER}"/mapping_supplemental_ci_images_*
do
  base_name=$(basename "${file}")
  namespace=${base_name#mapping_supplemental_ci_images_}
  namespace=${namespace//_/-}
  while read -r line;
  do
    [[ ${line} =~ ^#.* ]] && continue
    read -ra words <<< "${line}"
    i=0
    for word in "${words[@]}"
    do
      i=$((i+1))
      #[[ "$i" -eq 1 ]] && continue
      if [[ "$i" -eq 1 ]]
      then
        if [[ $word =~ ^docker.io/.+ ]]
        then
          >&2 echo "The mapping source must not be of the form '^docker.io/.+'."
          ERROR=1
        fi
        continue
      else
        if ! [[ $word =~ ^registry.ci.openshift.org/"${namespace}"/.+ ]]
        then
          >&2 echo "The mapping target ${word} must be of the form 'registry.ci.openshift.org/${namespace}/.+'."
          ERROR=1
        fi
      fi
    done
  done < "${file}"
done

if [[ "${ERROR}" -eq 0 ]]
then
  echo "All mapping files look good!"
else
  exit 1
fi
