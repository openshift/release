#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

python3 --version 
export CLOUDSDK_PYTHON=python3

function backoff() {
  local attempt=0
  local failed=0
  echo "Running Command '$*'"
  while true; do
    eval "$@" && failed=0 || failed=1
    if [[ $failed -eq 0 ]]; then
      break
    fi
    attempt=$(( attempt + 1 ))
    if [[ $attempt -gt 5 ]]; then
      break
    fi
    echo "command failed, retrying in $(( 2 ** attempt )) seconds"
    sleep $(( 2 ** attempt ))
  done
  return $failed
}

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

# Remove Tech Preview credentials requests
function remove_tp_creds_requests() {
  local path="$1"
  local keyword="$2"
  pushd "${path}"
  for FILE in *; do
    match_count=$(grep -c "${keyword}" "${FILE}")
    if [ $match_count -ne 0 ]; then
      echo "Remove CredentialsRequest '${FILE}' which is a '${keyword}' CR"
      rm -f "${FILE}"
    fi
  done
  popd
}

# Create credentials manifests file
function create_credentials_manifests() {
  local ns="$1"
  local name="$2"
  local b64_service_account_json="$3"
  local target_dir="$4"
  cat << EOF > ${target_dir}/99_${ns}_${name}-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  namespace: ${ns}
  name: ${name}
data:
  service_account.json: ${b64_service_account_json}
EOF
}

# release-controller always expose RELEASE_IMAGE_LATEST when job configuraiton defines release:latest image
echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST:-}"
# RELEASE_IMAGE_LATEST_FROM_BUILD_FARM is pointed to the same image as RELEASE_IMAGE_LATEST, 
# but for some ci jobs triggerred by remote api, RELEASE_IMAGE_LATEST might be overridden with 
# user specified image pullspec, to avoid auth error when accessing it, always use build farm 
# registry pullspec.
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"
# seem like release-controller does not expose RELEASE_IMAGE_INITIAL, even job configuraiton defines 
# release:initial image, once that, use 'oc get istag release:inital' to workaround it.
echo "RELEASE_IMAGE_INITIAL: ${RELEASE_IMAGE_INITIAL:-}"
if [[ -n ${RELEASE_IMAGE_INITIAL:-} ]]; then
  tmp_release_image_initial=${RELEASE_IMAGE_INITIAL}
  echo "Getting inital release image from RELEASE_IMAGE_INITIAL..."
elif oc get istag "release:initial" -n ${NAMESPACE} &>/dev/null; then
  tmp_release_image_initial=$(oc -n ${NAMESPACE} get istag "release:initial" -o jsonpath='{.tag.from.name}')
  echo "Getting inital release image from build farm imagestream: ${tmp_release_image_initial}"
fi
# For some ci upgrade job (stable N -> nightly N+1), RELEASE_IMAGE_INITIAL and 
# RELEASE_IMAGE_LATEST are pointed to different imgaes, RELEASE_IMAGE_INITIAL has 
# higher priority than RELEASE_IMAGE_LATEST
TESTING_RELEASE_IMAGE=""
if [[ -n ${tmp_release_image_initial:-} ]]; then
  TESTING_RELEASE_IMAGE=${tmp_release_image_initial}
else
  TESTING_RELEASE_IMAGE=${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}
fi
echo "TESTING_RELEASE_IMAGE: ${TESTING_RELEASE_IMAGE}"

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
GCP_SERVICE_ACCOUNT=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${GCP_SERVICE_ACCOUNT}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

## For OCP 4.15+
# With OCP 4.15 and 4.16, the credentials requests YAML files of CCO and 
# image-registry-operator don't have the section "spec.providerSpec.predefinedRoles", 
# and instead there's section "spec.providerSpec.permissions" in them. 
# So we pre-configured 2 custom roles accordingly. 
# Refer to https://gcsweb-qe-private-deck-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/qe-private-deck/pr-logs/pull/openshift_release/47131/rehearse-47131-periodic-ci-openshift-verification-tests-master-installation-nightly-4.15-gcp-ipi-cco-manual-users-static-f28/1742084668368359424/artifacts/gcp-ipi-cco-manual-users-static-f28/gcp-provision-cco-manual-users-static/build-log.txt
CCO_CUSTOM_ROLE="projects/${GOOGLE_PROJECT_ID}/roles/installer_qe_cco_permissions"
# The custom role includes below permissions, 
# - iam.roles.get
# - iam.serviceAccounts.get
# - iam.serviceAccountKeys.list
# - resourcemanager.projects.get
# - resourcemanager.projects.getIamPolicy
# - serviceusage.services.list

IMAGE_REGISTRY_CUSTOM_ROLE="projects/${GOOGLE_PROJECT_ID}/roles/installer_qe_image_registry_permissions"
# The custom role includes below permissions, 
# - storage.buckets.create
# - storage.buckets.delete
# - storage.buckets.get
# - storage.buckets.list
# - storage.buckets.createTagBinding
# - storage.buckets.listEffectiveTags
# - storage.objects.create
# - storage.objects.delete
# - storage.objects.get
# - storage.objects.list
##

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
MPREFIX="${SHARED_DIR}/manifest"
creds_requests_dir="$(mktemp -d)"
creds_keys_dir="$(mktemp -d)"
creds_manifests_dir="$(mktemp -d)"

echo "$(date -u --rfc-3339=seconds) - Extracting GCP credentials requests from the release image..."
ADDITIONAL_OC_EXTRACT_ARGS=""
if [[ "${EXTRACT_MANIFEST_INCLUDED}" == "true" ]]; then
  ADDITIONAL_OC_EXTRACT_ARGS="${ADDITIONAL_OC_EXTRACT_ARGS} --included --install-config=${SHARED_DIR}/install-config.yaml"
fi
echo "OC Version:"
which oc
oc version --client
oc adm release extract --help

dir=$(mktemp -d)
pushd "${dir}"
cp ${CLUSTER_PROFILE_DIR}/pull-secret pull-secret
oc registry login --to pull-secret
oc adm release extract --registry-config pull-secret --credentials-requests --cloud=gcp --to="${creds_requests_dir}" ${ADDITIONAL_OC_EXTRACT_ARGS} "${TESTING_RELEASE_IMAGE}"
rm pull-secret
popd

if [[ "${EXTRACT_MANIFEST_INCLUDED}" != "true" ]] && [[ "${FEATURE_SET}" != "TechPreviewNoUpgrade" ]] &&  [[ ! -f ${SHARED_DIR}/manifest_feature_gate.yaml ]]; then
  # workaround
  # Bug 2035903 - One redundant capi-operator credential requests in “oc adm extract --credentials-requests”
  # https://bugzilla.redhat.com/show_bug.cgi?id=2035903
  echo "$(date -u --rfc-3339=seconds) - WARN: Workaround for https://bugzilla.redhat.com/show_bug.cgi?id=2035903, removing TechPreviewNoUpgrade CredentialsRequests"
  annotation="TechPreviewNoUpgrade"
  remove_tp_creds_requests "${creds_requests_dir}" "${annotation}" || exit 1
fi

echo "$(date -u --rfc-3339=seconds) - Extracted GCP credentials requests to directory: ${creds_requests_dir}"
ls "${creds_requests_dir}"

echo "$(date -u --rfc-3339=seconds) - Creating GCP IAM service accounts for CCO manual mode..."
sa_suffix=${GCP_SERVICE_ACCOUNT#*@}
for yaml_filename in $(ls -p "${creds_requests_dir}"/*.yaml | awk -F'/' '{print $NF}'); do
  echo "$(date -u --rfc-3339=seconds) - Processing ${yaml_filename}"
  readarray -t roles < <(yq-go r "${creds_requests_dir}/${yaml_filename}" "spec.providerSpec.predefinedRoles" | sed 's/- //g')
  secret_name=$(yq-go r "${creds_requests_dir}/${yaml_filename}" "spec.secretRef.name")
  secret_namespace=$(yq-go r "${creds_requests_dir}/${yaml_filename}" "spec.secretRef.namespace")
  metadata_name=$(yq-go r "${creds_requests_dir}/${yaml_filename}" "metadata.name")
  if [ -z "$secret_name" ] || [ -z "$secret_namespace" ] || [ -z "$metadata_name" ]; then
    echo "$(date -u --rfc-3339=seconds) - ERROR: spec.secretRef.name, spec.secretRef.namespace or metadata.name is empty"
    cat "${creds_requests_dir}/${yaml_filename}"
    exit 1
  fi
  if [ -z "${roles:-}" ]; then
    if [[ "${metadata_name}" =~ cloud-credential-operator ]]; then
      echo "$(date -u --rfc-3339=seconds) - Using pre-configured custom role for cloud-credential-operator"
      cmd="gcloud iam roles describe $(basename ${CCO_CUSTOM_ROLE}) --project=${GOOGLE_PROJECT_ID}"
      run_command "${cmd}"
      cmd="yq-go r ${creds_requests_dir}/${yaml_filename} spec.providerSpec.permissions"
      run_command "${cmd}"
      roles=("${CCO_CUSTOM_ROLE}")
    elif [[ "${metadata_name}" =~ openshift-image-registry ]]; then
      echo "$(date -u --rfc-3339=seconds) - Using pre-configured custom role for openshift-image-registry"
      cmd="gcloud iam roles describe $(basename ${IMAGE_REGISTRY_CUSTOM_ROLE}) --project=${GOOGLE_PROJECT_ID}"
      run_command "${cmd}"
      cmd="yq-go r ${creds_requests_dir}/${yaml_filename} spec.providerSpec.permissions"
      run_command "${cmd}"
      roles=("${IMAGE_REGISTRY_CUSTOM_ROLE}")
    else
      echo "$(date -u --rfc-3339=seconds) - ERROR: Failed to determine the required permissions/roles"
      cat "${creds_requests_dir}/${yaml_filename}"
      exit 1
    fi
  fi
  echo "$(date -u --rfc-3339=seconds) - The interested roles '${roles[*]}'"

  # Service account name must be between 6 and 30 characters, the display name must be lower than 100 characters
  sa_name="${CLUSTER_NAME:0:12}-${metadata_name:0:11}"-`echo $RANDOM`
  sa_display_name="${CLUSTER_NAME}-${metadata_name}"
  sa_display_name=${sa_display_name:0:100}
  sa_email="${sa_name}@${sa_suffix}"
  sa_json_file="${creds_keys_dir}/${sa_name}.json"
  echo "$(date -u --rfc-3339=seconds) - Creating GCP IAM service account '${sa_email}'..."
  cmd="gcloud iam service-accounts create ${sa_name} --display-name=${sa_display_name}"
  run_command "$cmd"
  
  echo "$(date -u --rfc-3339=seconds) - Granting roles to IAM service account '${sa_email}'..."
  for role in "${roles[@]}"; do 
    cmd="gcloud projects add-iam-policy-binding ${GOOGLE_PROJECT_ID} --member='serviceAccount:${sa_email}' --role='$role' 1>/dev/null"
    backoff "$cmd"
  done

  echo "$(date -u --rfc-3339=seconds) - Creating IAM service account key for '${sa_email}'..."
  cmd="gcloud iam service-accounts keys create ${sa_json_file} --iam-account=${sa_email}"
  run_command "$cmd"
  if [ -f "$sa_json_file" ]; then
    echo "$(date -u --rfc-3339=seconds) - Creating the credentials manifests file..."
    create_credentials_manifests "${secret_namespace}" "${secret_name}" "$(base64 ${sa_json_file} -w 0)" "${creds_manifests_dir}"
  else
    echo "$(date -u --rfc-3339=seconds) - ERROR: Failed to create IAM service account key" &&  exit 1
  fi  
done

echo "$(date -u --rfc-3339=seconds) - Copy the credentials manifests to ${SHARED_DIR}"
cd "${creds_manifests_dir}"
for FILE in *; do cp -v $FILE "${MPREFIX}_$FILE"; done
ls -l "${SHARED_DIR}"/manifest_*
