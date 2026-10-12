#!/bin/bash

# queue function stolen from https://steps.ci.openshift.org/reference/gather-extra ;-)
function queue() {
  local TARGET="${1}"
  shift
  local LIVE
  LIVE="$(jobs | wc -l)"
  while [[ "${LIVE}" -ge 45 ]]; do
    sleep 1
    LIVE="$(jobs | wc -l)"
  done
  echo "${@}"
  if [[ -n "${FILTER:-}" ]]; then
    "${@}" | "${FILTER}" >"${TARGET}" &
  else
    "${@}" >"${TARGET}" &
  fi
}

# Resources
CRD_LIST=$(oc get crds -o jsonpath='{.items[?(@.spec.group=="toolchain.dev.openshift.com")].metadata.name}')
for CRD in ${CRD_LIST}; do
  queue ${ARTIFACT_DIR}/${CRD}.json oc --insecure-skip-tls-verify --request-timeout=5s get ${CRD} --all-namespaces -o json
done