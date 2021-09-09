#! /bin/bash

set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

INSTANCE_PREFIX="${NAMESPACE}"-"${JOB_NAME_HASH}"
GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
GOOGLE_COMPUTE_REGION="${LEASED_RESOURCE}"
GOOGLE_COMPUTE_ZONE="$(< ${SHARED_DIR}/openshift_gcp_compute_zone)"
if [[ -z "${GOOGLE_COMPUTE_ZONE}" ]]; then
  echo "Expected \${SHARED_DIR}/openshift_gcp_compute_zone to contain the GCP zone"
  exit 1
fi

mkdir -p "${HOME}"/.ssh

mock-nss.sh

# gcloud compute will use this key rather than create a new one
cp "${CLUSTER_PROFILE_DIR}"/ssh-privatekey "${HOME}"/.ssh/google_compute_engine
chmod 0600 "${HOME}"/.ssh/google_compute_engine
cp "${CLUSTER_PROFILE_DIR}"/ssh-publickey "${HOME}"/.ssh/google_compute_engine.pub
echo 'ServerAliveInterval 30' | tee -a "${HOME}"/.ssh/config
echo 'ServerAliveCountMax 1200' | tee -a "${HOME}"/.ssh/config
chmod 0600 "${HOME}"/.ssh/config

# Copy pull secret to user home
cp "${CLUSTER_PROFILE_DIR}"/pull-secret "${HOME}"/pull-secret

gcloud auth activate-service-account --quiet --key-file "${CLUSTER_PROFILE_DIR}"/gce.json
gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"


cat <<EOF > "${HOME}"/suite.txt
"[sig-apps] Daemon set [Serial] should rollback without unnecessary restarts [Conformance] [Suite:openshift/conformance/serial/minimal] [Suite:k8s]"
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs  should adhere to Three Laws of Controllers [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs adoption will orphan all RCs and adopt them back when recreated [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs generation should deploy based on a status version bump [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs ignores deployer and lets the config with a NewReplicationControllerCreated reason should let the deployment config with a" NewReplicationControllerCreated reason [Suite:openshift/conformance/parallel]
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs initially should not deploy if pods never transition to ready [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs keep the deployer pod invariant valid should deal with cancellation after deployer pod succeeded [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs keep the deployer pod invariant valid should deal with cancellation of running deployment [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs keep the deployer pod invariant valid should deal with config change in case the deployment is still running" [Suite:openshift/conformance/parallel]
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs paused should disable actions on deployments [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs rolled back should rollback to an older deployment [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs should respect image stream tag reference policy resolve the image pull spec [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs viewing rollout history should print the rollout history [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs when changing image change trigger should successfully trigger from an updated image [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs when run iteratively should immediately start a new deployment [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs when run iteratively should only deploy the last deployment [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs when tagging images should successfully tag the deployed image [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs with custom deployments should run the custom deployment steps [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs with enhanced status should include various info in status [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs with env in params referencing the configmap should expand the config map key to a value [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs with failing hook should get all logs from retried hooks [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs with minimum ready seconds set should not transition the deployment to Complete before satisfied [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs with multiple image change triggers should run a successful deployment with a trigger used by different containers" [Suite:openshift/conformance/parallel]
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs with multiple image change triggers should run a successful deployment with multiple triggers [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs with revision history limits should never persist more old deployments than acceptable after being observed by the controller" [Suite:openshift/conformance/parallel]
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs with test deployments should run a deployment to completion and then scale to zero [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs won't deploy RC with unresolved images when patched with empty image [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:Jobs] Users should be able to create and run a job in a user project [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:OpenShiftControllerManager] TestDeployScale [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:OpenShiftControllerManager] TestDeploymentConfigDefaults [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:OpenShiftControllerManager] TestTriggers_MultipleICTs [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:OpenShiftControllerManager] TestTriggers_configChange [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:OpenShiftControllerManager] TestTriggers_imageChange [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:OpenShiftControllerManager] TestTriggers_imageChange_nonAutomatic [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:OpenShiftControllerManager] TestTriggers_manual [Suite:openshift/conformance/parallel]"
EOF

# scp and install microshift.service
  LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/suite.txt rhel8user@"${INSTANCE_PREFIX}":~/suite.txt

