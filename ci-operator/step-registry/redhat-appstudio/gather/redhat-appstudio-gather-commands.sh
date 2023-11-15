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

# Appstudio resources
queue ${ARTIFACT_DIR}/applications_appstudio.json  oc --insecure-skip-tls-verify --request-timeout=5s get applications.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/buildpipelineselectors.json  oc --insecure-skip-tls-verify --request-timeout=5s get buildpipelineselectors.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/componentdetectionqueries.json  oc --insecure-skip-tls-verify --request-timeout=5s get componentdetectionqueries.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/components.json  oc --insecure-skip-tls-verify --request-timeout=5s get components.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/deploymenttargetclaims.json  oc --insecure-skip-tls-verify --request-timeout=5s get deploymenttargetclaims.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/deploymenttargetclasses.json  oc --insecure-skip-tls-verify --request-timeout=5s get deploymenttargetclasses.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/deploymenttargets.json  oc --insecure-skip-tls-verify --request-timeout=5s get deploymenttargets.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/enterprisecontractpolicies.json  oc --insecure-skip-tls-verify --request-timeout=5s get enterprisecontractpolicies.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/environments.json  oc --insecure-skip-tls-verify --request-timeout=5s get environments.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/integrationtestscenarios.json  oc --insecure-skip-tls-verify --request-timeout=5s get integrationtestscenarios.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/internalrequests.json  oc --insecure-skip-tls-verify --request-timeout=5s get internalrequests.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/promotionruns.json  oc --insecure-skip-tls-verify --request-timeout=5s get promotionruns.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/releaseplanadmissions.json  oc --insecure-skip-tls-verify --request-timeout=5s get releaseplanadmissions.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/releaseplans.json  oc --insecure-skip-tls-verify --request-timeout=5s get releaseplans.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/releases.json  oc --insecure-skip-tls-verify --request-timeout=5s get releases.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/releasestrategies.json  oc --insecure-skip-tls-verify --request-timeout=5s get releasestrategies.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/snapshotenvironmentbindings.json  oc --insecure-skip-tls-verify --request-timeout=5s get snapshotenvironmentbindings.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/snapshots.json  oc --insecure-skip-tls-verify --request-timeout=5s get snapshots.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/spiaccesschecks.json  oc --insecure-skip-tls-verify --request-timeout=5s get spiaccesschecks.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/spiaccesstokenbindings.json  oc --insecure-skip-tls-verify --request-timeout=5s get spiaccesstokenbindings.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/spiaccesstokendataupdates.json  oc --insecure-skip-tls-verify --request-timeout=5s get spiaccesstokendataupdates.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/spiaccesstokens.json  oc --insecure-skip-tls-verify --request-timeout=5s get spiaccesstokens.appstudio.redhat.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/spifilecontentrequests.json  oc --insecure-skip-tls-verify --request-timeout=5s get spifilecontentrequests.appstudio.redhat.com --all-namespaces -o json

# JBS resources (jvm-build-service)
queue ${ARTIFACT_DIR}/artifactbuilds.json  oc --insecure-skip-tls-verify --request-timeout=5s get artifactbuilds.jvmbuildservice.io --all-namespaces -o json
queue ${ARTIFACT_DIR}/dependencybuilds.json  oc --insecure-skip-tls-verify --request-timeout=5s get dependencybuilds.jvmbuildservice.io --all-namespaces -o json
queue ${ARTIFACT_DIR}/jbsconfigs.json  oc --insecure-skip-tls-verify --request-timeout=5s get jbsconfigs.jvmbuildservice.io --all-namespaces -o json
queue ${ARTIFACT_DIR}/rebuiltartifacts.json  oc --insecure-skip-tls-verify --request-timeout=5s get rebuiltartifacts.jvmbuildservice.io --all-namespaces -o json
queue ${ARTIFACT_DIR}/systemconfigs.json  oc --insecure-skip-tls-verify --request-timeout=5s get systemconfigs.jvmbuildservice.io --all-namespaces -o json

# ArgoCD resources
queue ${ARTIFACT_DIR}/applications_argoproj.json  oc --insecure-skip-tls-verify --request-timeout=5s get applications.argoproj.io --all-namespaces -o json
queue ${ARTIFACT_DIR}/applicationsets.json  oc --insecure-skip-tls-verify --request-timeout=5s get applicationsets.argoproj.io --all-namespaces -o json
queue ${ARTIFACT_DIR}/appprojects.json  oc --insecure-skip-tls-verify --request-timeout=5s get appprojects.argoproj.io --all-namespaces -o json
queue ${ARTIFACT_DIR}/argocds.json  oc --insecure-skip-tls-verify --request-timeout=5s get argocds.argoproj.io --all-namespaces -o json

# Managed-gitops resources
queue ${ARTIFACT_DIR}/gitopsdeploymentmanagedenvironments.json  oc --insecure-skip-tls-verify --request-timeout=5s get gitopsdeploymentmanagedenvironments.managed-gitops.redhat.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/gitopsdeploymentrepositorycredentials.json  oc --insecure-skip-tls-verify --request-timeout=5s get gitopsdeploymentrepositorycredentials.managed-gitops.redhat.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/gitopsdeployments.json  oc --insecure-skip-tls-verify --request-timeout=5s get gitopsdeployments.managed-gitops.redhat.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/gitopsdeploymentsyncruns.json  oc --insecure-skip-tls-verify --request-timeout=5s get gitopsdeploymentsyncruns.managed-gitops.redhat.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/operations.json  oc --insecure-skip-tls-verify --request-timeout=5s get operations.managed-gitops.redhat.com --all-namespaces -o json

# Tekton resources
queue ${ARTIFACT_DIR}/repositories.json  oc --insecure-skip-tls-verify --request-timeout=5s get repositories.pipelinesascode.tekton.dev --all-namespaces -o json
queue ${ARTIFACT_DIR}/resolutionrequests.json  oc --insecure-skip-tls-verify --request-timeout=5s get resolutionrequests.resolution.tekton.dev --all-namespaces -o json
queue ${ARTIFACT_DIR}/pipelineresources.json  oc --insecure-skip-tls-verify --request-timeout=5s get pipelineresources.tekton.dev --all-namespaces -o json
queue ${ARTIFACT_DIR}/pipelineruns.json  oc --insecure-skip-tls-verify --request-timeout=5s get pipelineruns.tekton.dev --all-namespaces -o json
queue ${ARTIFACT_DIR}/pipelines.json  oc --insecure-skip-tls-verify --request-timeout=5s get pipelines.tekton.dev --all-namespaces -o json
queue ${ARTIFACT_DIR}/runs.json  oc --insecure-skip-tls-verify --request-timeout=5s get runs.tekton.dev --all-namespaces -o json
queue ${ARTIFACT_DIR}/taskruns.json  oc --insecure-skip-tls-verify --request-timeout=5s get taskruns.tekton.dev --all-namespaces -o json
queue ${ARTIFACT_DIR}/tasks.json  oc --insecure-skip-tls-verify --request-timeout=5s get tasks.tekton.dev --all-namespaces -o json
queue ${ARTIFACT_DIR}/eventlisteners.json  oc --insecure-skip-tls-verify --request-timeout=5s get eventlisteners.triggers.tekton.dev --all-namespaces -o json
queue ${ARTIFACT_DIR}/triggerbindings.json  oc --insecure-skip-tls-verify --request-timeout=5s get triggerbindings.triggers.tekton.dev --all-namespaces -o json
queue ${ARTIFACT_DIR}/triggers.json  oc --insecure-skip-tls-verify --request-timeout=5s get triggers.triggers.tekton.dev --all-namespaces -o json
queue ${ARTIFACT_DIR}/triggertemplates.json  oc --insecure-skip-tls-verify --request-timeout=5s get triggertemplates.triggers.tekton.dev --all-namespaces -o json

# Toolchain resources
queue ${ARTIFACT_DIR}/bannedusers.json  oc --insecure-skip-tls-verify --request-timeout=5s get bannedusers.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/masteruserrecords.json  oc --insecure-skip-tls-verify --request-timeout=5s get masteruserrecords.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/memberoperatorconfigs.json  oc --insecure-skip-tls-verify --request-timeout=5s get memberoperatorconfigs.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/memberstatuses.json  oc --insecure-skip-tls-verify --request-timeout=5s get memberstatuses.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/notifications.json  oc --insecure-skip-tls-verify --request-timeout=5s get notifications.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/nstemplatesets.json  oc --insecure-skip-tls-verify --request-timeout=5s get nstemplatesets.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/nstemplatetiers.json  oc --insecure-skip-tls-verify --request-timeout=5s get nstemplatetiers.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/socialevents.json  oc --insecure-skip-tls-verify --request-timeout=5s get socialevents.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/spacebindings.json  oc --insecure-skip-tls-verify --request-timeout=5s get spacebindings.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/spacerequests.json  oc --insecure-skip-tls-verify --request-timeout=5s get spacerequests.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/spaces.json  oc --insecure-skip-tls-verify --request-timeout=5s get spaces.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/tiertemplates.json  oc --insecure-skip-tls-verify --request-timeout=5s get tiertemplates.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/toolchainclusters.json  oc --insecure-skip-tls-verify --request-timeout=5s get toolchainclusters.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/toolchainconfigs.json  oc --insecure-skip-tls-verify --request-timeout=5s get toolchainconfigs.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/toolchainstatuses.json  oc --insecure-skip-tls-verify --request-timeout=5s get toolchainstatuses.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/useraccounts.json  oc --insecure-skip-tls-verify --request-timeout=5s get useraccounts.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/usersignups.json  oc --insecure-skip-tls-verify --request-timeout=5s get usersignups.toolchain.dev.openshift.com --all-namespaces -o json
queue ${ARTIFACT_DIR}/usertiers.json  oc --insecure-skip-tls-verify --request-timeout=5s get usertiers.toolchain.dev.openshift.com --all-namespaces -o json


# Non-namespaced resources
queue ${ARTIFACT_DIR}/idlers.json  oc --insecure-skip-tls-verify --request-timeout=5s get idlers.toolchain.dev.openshift.com -o json
queue ${ARTIFACT_DIR}/tektonaddons.json  oc --insecure-skip-tls-verify --request-timeout=5s get tektonaddons.operator.tekton.dev -o json
queue ${ARTIFACT_DIR}/tektonchains.json  oc --insecure-skip-tls-verify --request-timeout=5s get tektonchains.operator.tekton.dev -o json
queue ${ARTIFACT_DIR}/tektonconfigs.json  oc --insecure-skip-tls-verify --request-timeout=5s get tektonconfigs.operator.tekton.dev -o json
queue ${ARTIFACT_DIR}/tektonhubs.json  oc --insecure-skip-tls-verify --request-timeout=5s get tektonhubs.operator.tekton.dev -o json
queue ${ARTIFACT_DIR}/tektoninstallersets.json  oc --insecure-skip-tls-verify --request-timeout=5s get tektoninstallersets.operator.tekton.dev -o json
queue ${ARTIFACT_DIR}/tektonpipelines.json  oc --insecure-skip-tls-verify --request-timeout=5s get tektonpipelines.operator.tekton.dev -o json
queue ${ARTIFACT_DIR}/tektontriggers.json  oc --insecure-skip-tls-verify --request-timeout=5s get tektontriggers.operator.tekton.dev -o json
queue ${ARTIFACT_DIR}/clustertasks.json  oc --insecure-skip-tls-verify --request-timeout=5s get clustertasks.tekton.dev -o json
queue ${ARTIFACT_DIR}/clusterinterceptors.json  oc --insecure-skip-tls-verify --request-timeout=5s get clusterinterceptors.triggers.tekton.dev -o json
queue ${ARTIFACT_DIR}/clustertriggerbindings.json  oc --insecure-skip-tls-verify --request-timeout=5s get clustertriggerbindings.triggers.tekton.dev -o json
queue ${ARTIFACT_DIR}/clusterregistrars.json  oc --insecure-skip-tls-verify --request-timeout=5s get clusterregistrars.singapore.open-cluster-management.io -o json
queue ${ARTIFACT_DIR}/gitopsservices.json  oc --insecure-skip-tls-verify --request-timeout=5s get gitopsservices.pipelines.openshift.io -o json


# Must gather steps to collect OpenShift logs
mkdir -p ${ARTIFACT_DIR}/must-gather-appstudio
oc --insecure-skip-tls-verify adm must-gather --timeout='10m' --dest-dir ${ARTIFACT_DIR}/must-gather-appstudio > ${ARTIFACT_DIR}/must-gather-appstudio/must-gather.log
mkdir -p ${ARTIFACT_DIR}/must-gather-network-appstudio
oc --insecure-skip-tls-verify adm must-gather --timeout='10m' --dest-dir ${ARTIFACT_DIR}/must-gather-network-appstudio -- gather_network_logs > ${ARTIFACT_DIR}/must-gather-network-appstudio/must-gather-network.log
