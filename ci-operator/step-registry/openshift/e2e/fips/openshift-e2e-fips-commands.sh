#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

oc --request-timeout=60s get nodes -o jsonpath --template '{range .items[*]}{.metadata.name}{"\n"}{end}' > "${TMPDIR}/node-names" &
wait "$!"

cat "${TMPDIR}/node-names" | sort | while read -r NODE_NAME
do
  echo "Checking FIPS for node ${NODE_NAME}"
  attempt=0
  while true; do
    out=$(oc --request-timeout=60s -n default debug "node/${NODE_NAME}" -- cat /proc/sys/crypto/fips_enabled || true) &
    wait "$!"
    if [[ ! -z "${out}" ]]; then
        break
    fi
    attempt=$(( attempt + 1 ))
    if [[ $attempt -gt 3 ]]; then
        break
    fi
    echo "command failed, $(( 4 - $attempt )) retries left"
    sleep 5
  done

  if [[ -z "${out}" ]]; then
    echo "oc debug node/${NODE_NAME} failed" >&2
    exit 1
  fi
  if [[ "${FIPS_ENABLED}" = 'true' ]]; then
    if [[ "${out}" -ne 1 ]]; then
      echo "FIPS not enabled on node ${NODE_NAME} but should be, exiting" >&2
      exit 1
    fi
  else
    if [[ "${out}" -ne 0 ]]; then
      echo "FIPS is enabled on node ${NODE_NAME} but should not be, exiting" >&2
      exit 1
    fi
  fi
done
