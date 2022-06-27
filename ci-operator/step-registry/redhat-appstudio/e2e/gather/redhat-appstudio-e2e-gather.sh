#!/bin/bash
set -x

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

# Appstudio resources
queue ${ARTIFACTS_DIR}/applicationpromotionruns.json  oc --insecure-skip-tls-verify --request-timeout=5s get applicationpromotionruns.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACTS_DIR}/applications_appstudio.json  oc --insecure-skip-tls-verify --request-timeout=5s get applications.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACTS_DIR}/applicationsnapshotenvironmentbindings.json  oc --insecure-skip-tls-verify --request-timeout=5s get applicationsnapshotenvironmentbindings.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACTS_DIR}/applicationsnapshots.json  oc --insecure-skip-tls-verify --request-timeout=5s get applicationsnapshots.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACTS_DIR}/componentdetectionqueries.json  oc --insecure-skip-tls-verify --request-timeout=5s get componentdetectionqueries.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACTS_DIR}/components.json  oc --insecure-skip-tls-verify --request-timeout=5s get components.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACTS_DIR}/enterprisecontractpolicies.json  oc --insecure-skip-tls-verify --request-timeout=5s get enterprisecontractpolicies.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACTS_DIR}/environments.json  oc --insecure-skip-tls-verify --request-timeout=5s get environments.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACTS_DIR}/integrationtestscenarios.json  oc --insecure-skip-tls-verify --request-timeout=5s get integrationtestscenarios.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACTS_DIR}/releaselinks.json  oc --insecure-skip-tls-verify --request-timeout=5s get releaselinks.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACTS_DIR}/releases.json  oc --insecure-skip-tls-verify --request-timeout=5s get releases.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACTS_DIR}/releasestrategies.json  oc --insecure-skip-tls-verify --request-timeout=5s get releasestrategies.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACTS_DIR}/spiaccesschecks.json  oc --insecure-skip-tls-verify --request-timeout=5s get spiaccesschecks.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACTS_DIR}/spiaccesstokenbindings.json  oc --insecure-skip-tls-verify --request-timeout=5s get spiaccesstokenbindings.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACTS_DIR}/spiaccesstokendataupdates.json  oc --insecure-skip-tls-verify --request-timeout=5s get spiaccesstokendataupdates.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACTS_DIR}/spiaccesstokens.json  oc --insecure-skip-tls-verify --request-timeout=5s get spiaccesstokens.appstudio.redhat.com --all-namespaces -o json

# ArgoCD ${ARTIFACTS_DIR}
queue ${ARTIFACTS_DIR}/applications_argoproj.json  oc --insecure-skip-tls-verify --request-timeout=5s get applications.argoproj.io --all-namespaces -o json
queue ${ARTIFACTS_DIR}/applicationsets.json  oc --insecure-skip-tls-verify --request-timeout=5s get applicationsets.argoproj.io --all-namespaces -o json
queue ${ARTIFACTS_DIR}/appprojects.json  oc --insecure-skip-tls-verify --request-timeout=5s get appprojects.argoproj.io --all-namespaces -o json
queue ${ARTIFACTS_DIR}/argocds.json  oc --insecure-skip-tls-verify --request-timeout=5s get argocds.argoproj.io --all-namespaces -o json

# Managed-gitops ${ARTIFACTS_DIR}
queue ${ARTIFACTS_DIR}/gitopsdeployments.json  oc --insecure-skip-tls-verify --request-timeout=5s get gitopsdeployments.managed-gitops.redhat.com --all-namespaces -o json
queue ${ARTIFACTS_DIR}/gitopsdeploymentsyncruns.json  oc --insecure-skip-tls-verify --request-timeout=5s get gitopsdeploymentsyncruns.managed-gitops.redhat.com --all-namespaces -o json
queue ${ARTIFACTS_DIR}/operations.json  oc --insecure-skip-tls-verify --request-timeout=5s get operations.managed-gitops.redhat.com --all-namespaces -o json

# Tekton ${ARTIFACTS_DIR}
queue ${ARTIFACTS_DIR}/repositories.json  oc --insecure-skip-tls-verify --request-timeout=5s get repositories.pipelinesascode.tekton.dev --all-namespaces -o json
queue ${ARTIFACTS_DIR}/conditions.json  oc --insecure-skip-tls-verify --request-timeout=5s get conditions.tekton.dev --all-namespaces -o json
queue ${ARTIFACTS_DIR}/pipelineresources.json  oc --insecure-skip-tls-verify --request-timeout=5s get pipelineresources.tekton.dev --all-namespaces -o json
queue ${ARTIFACTS_DIR}/pipelineruns.json  oc --insecure-skip-tls-verify --request-timeout=5s get pipelineruns.tekton.dev --all-namespaces -o json
queue ${ARTIFACTS_DIR}/pipelines.json  oc --insecure-skip-tls-verify --request-timeout=5s get pipelines.tekton.dev --all-namespaces -o json
queue ${ARTIFACTS_DIR}/runs.json  oc --insecure-skip-tls-verify --request-timeout=5s get runs.tekton.dev --all-namespaces -o json
queue ${ARTIFACTS_DIR}/taskruns.json  oc --insecure-skip-tls-verify --request-timeout=5s get taskruns.tekton.dev --all-namespaces -o json
queue ${ARTIFACTS_DIR}/tasks.json  oc --insecure-skip-tls-verify --request-timeout=5s get tasks.tekton.dev --all-namespaces -o json
queue ${ARTIFACTS_DIR}/eventlisteners.json  oc --insecure-skip-tls-verify --request-timeout=5s get eventlisteners.triggers.tekton.dev --all-namespaces -o json
queue ${ARTIFACTS_DIR}/triggerbindings.json  oc --insecure-skip-tls-verify --request-timeout=5s get triggerbindings.triggers.tekton.dev --all-namespaces -o json
queue ${ARTIFACTS_DIR}/triggers.json  oc --insecure-skip-tls-verify --request-timeout=5s get triggers.triggers.tekton.dev --all-namespaces -o json
queue ${ARTIFACTS_DIR}/triggertemplates.json  oc --insecure-skip-tls-verify --request-timeout=5s get triggertemplates.triggers.tekton.dev --all-namespaces -o json

