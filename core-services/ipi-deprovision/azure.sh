#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

function queue() {
  local LIVE="$(jobs | wc -l)"
  while [[ "${LIVE}" -ge 10 ]]; do
    sleep 1
    LIVE="$(jobs | wc -l)"
  done
  echo "${@}"
  "${@}" &
}

function deprovision() {
  WORKDIR="${1}"
  timeout --signal=SIGQUIT 30m openshift-install --dir "${WORKDIR}" --log-level error destroy cluster && touch "${WORKDIR}/success" || touch "${WORKDIR}/failure"
}

logdir="${ARTIFACTS}/deprovision"
mkdir -p "${logdir}"

azure_cluster_age_cutoff="$(TZ=":Africa/Abidjan" date --date="${CLUSTER_TTL}" '+%Y-%m-%dT%H:%M+0000')"
echo "deprovisioning clusters with an expirationDate before ${azure_cluster_age_cutoff} in Azure ..."
for rg in $( az group list --output json | jq --arg date "${azure_cluster_age_cutoff}" -r -S '.[] | select(.tags.openshift_creationDate | . != null and . < $date) | .name' ); do
  workdir="${logdir}/${rg}"
  mkdir -p "${workdir}"
  cat <<EOF >"${workdir}/metadata.json"
{
  "azure":{
    "cloudName": "AzurePublicCloud",
    "resourceGroupName": "rg",
    "baseDomainResourceGroupName": "os4-common"
  }
}
EOF
    echo "will deprovision Azure cluster in resource group ${rg}"
done

resource_groups=$( find "${logdir}" -mindepth 1 -type d )
for workdir in $(shuf <<< ${resource_groups}); do
  queue deprovision "${workdir}"
done

wait

FAILED="$(find ${resource_groups} -name failure -printf '%H\n' | sort)"
if [[ -n "${FAILED}" ]]; then
  echo "Deprovision failed on the clusters in the following resource groups:"
  xargs --max-args 1 basename <<< $FAILED
  exit 1
fi

echo "Deprovision finished successfully"
