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
queue ${ARTIFACT_DIR}/bannedusers.json oc --insecure-skip-tls-verify --request-timeout=5s get bannedusers.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/idlers.json oc --insecure-skip-tls-verify --request-timeout=5s get idlers.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/masteruserrecords.json oc --insecure-skip-tls-verify --request-timeout=5s get masteruserrecords.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/memberoperatorconfigs.json oc --insecure-skip-tls-verify --request-timeout=5s get memberoperatorconfigs.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/memberstatuses.json oc --insecure-skip-tls-verify --request-timeout=5s get memberstatuses.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/notifications.json oc --insecure-skip-tls-verify --request-timeout=5s get notifications.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/nstemplatesets.json oc --insecure-skip-tls-verify --request-timeout=5s get nstemplatesets.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/nstemplatetiers.json oc --insecure-skip-tls-verify --request-timeout=5s get nstemplatetiers.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/proxyplugins.json oc --insecure-skip-tls-verify --request-timeout=5s get proxyplugins.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/socialevents.json oc --insecure-skip-tls-verify --request-timeout=5s get socialevents.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/spacebindings.json oc --insecure-skip-tls-verify --request-timeout=5s get spacebindings.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/spacebindingrequests.json oc --insecure-skip-tls-verify --request-timeout=5s get spacebindingrequests.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/spaceprovisionerconfigs.json oc --insecure-skip-tls-verify --request-timeout=5s get spaceprovisionerconfigs.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/spacerequests.json oc --insecure-skip-tls-verify --request-timeout=5s get spacerequests.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/spaces.json oc --insecure-skip-tls-verify --request-timeout=5s get spaces.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/tiertemplates.json oc --insecure-skip-tls-verify --request-timeout=5s get tiertemplates.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/tiertemplaterevisions.json oc --insecure-skip-tls-verify --request-timeout=5s get tiertemplaterevisions.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/toolchainclusters.json oc --insecure-skip-tls-verify --request-timeout=5s get toolchainclusters.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/toolchainconfigs.json oc --insecure-skip-tls-verify --request-timeout=5s get toolchainconfigs.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/toolchainstatuses.json oc --insecure-skip-tls-verify --request-timeout=5s get toolchainstatuses.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/usersignups.json oc --insecure-skip-tls-verify --request-timeout=5s get usersignups.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/usertiers.json oc --insecure-skip-tls-verify --request-timeout=5s get usertiers.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/workspaces.json oc --insecure-skip-tls-verify --request-timeout=5s get workspaces.toolchain.dev.openshift.com --all-namespaces -o json
