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
# With OCP 4.15 and 4.16, the credentials requests YAML files have the section 
# "spec.providerSpec.permissions", for which we need to use the pre-configured custom roles. 
# Note: those custom roles were created, and would be maintained, by 'ccoctl', see https://console.cloud.google.com/iam-admin/roles.
CCO_CUSTOM_ROLE="projects/${GOOGLE_PROJECT_ID}/roles/openshiftqe_cloudcredentialoperatorgcprocre"
CNCC_CUSTOM_ROLE="projects/${GOOGLE_PROJECT_ID}/roles/openshiftqe_openshiftcloudnetworkconfigcont"
CLUSTER_API_CUSTOM_ROLE="projects/${GOOGLE_PROJECT_ID}/roles/openshiftqe_openshiftclusterapigcp"
CCM_CUSTOM_ROLE="projects/${GOOGLE_PROJECT_ID}/roles/openshiftqe_openshiftgcpccm"
STORAGE_CUSTOM_ROLE="projects/${GOOGLE_PROJECT_ID}/roles/openshiftqe_openshiftgcppdcsidriveroperator"
IMAGE_REGISTRY_CUSTOM_ROLE="projects/${GOOGLE_PROJECT_ID}/roles/openshiftqe_openshiftimageregistrygcs"
INGRESS_CUSTOM_ROLE="projects/${GOOGLE_PROJECT_ID}/roles/openshiftqe_openshiftingressgcp"
MACHINE_API_CUSTOM_ROLE="projects/${GOOGLE_PROJECT_ID}/roles/openshiftqe_openshiftmachineapigcp"

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
  readarray -t permissions < <(yq-go r "${creds_requests_dir}/${yaml_filename}" "spec.providerSpec.permissions" | sed 's/- //g')
  secret_name=$(yq-go r "${creds_requests_dir}/${yaml_filename}" "spec.secretRef.name")
  secret_namespace=$(yq-go r "${creds_requests_dir}/${yaml_filename}" "spec.secretRef.namespace")
  metadata_name=$(yq-go r "${creds_requests_dir}/${yaml_filename}" "metadata.name")
  if [ -z "$secret_name" ] || [ -z "$secret_namespace" ] || [ -z "$metadata_name" ]; then
    echo "$(date -u --rfc-3339=seconds) - ERROR: spec.secretRef.name, spec.secretRef.namespace or metadata.name is empty"
    cat "${creds_requests_dir}/${yaml_filename}"
    exit 1
  fi
  if [ -n "${permissions:-}" ]; then
    case "${metadata_name}" in
      cloud-credential-operator-gcp-ro-creds)
      additional_custom_role="${CCO_CUSTOM_ROLE}"
      echo "$(date -u --rfc-3339=seconds) - Using pre-configured custom role '${additional_custom_role}' for openshift-cloud-credential-operator"
      ;;
      openshift-cloud-network-config-controller-gcp)
      additional_custom_role="${CNCC_CUSTOM_ROLE}"
      echo "$(date -u --rfc-3339=seconds) - Using pre-configured custom role '${additional_custom_role}' for openshift-cloud-network-config-controller"
      ;;
      openshift-cluster-api-gcp)
      additional_custom_role="${CLUSTER_API_CUSTOM_ROLE}"
      echo "$(date -u --rfc-3339=seconds) - Using pre-configured custom role '${additional_custom_role}' for openshift-cluster-api"
      ;;
      openshift-gcp-ccm)
      additional_custom_role="${CCM_CUSTOM_ROLE}"
      echo "$(date -u --rfc-3339=seconds) - Using pre-configured custom role '${additional_custom_role}' for openshift-cloud-controller-manager"
      ;;
      openshift-gcp-pd-csi-driver-operator)
      additional_custom_role="${STORAGE_CUSTOM_ROLE}"
      echo "$(date -u --rfc-3339=seconds) - Using pre-configured custom role '${additional_custom_role}' for openshift-cluster-csi-drivers"
      ;;
      openshift-image-registry-gcs)
      additional_custom_role="${IMAGE_REGISTRY_CUSTOM_ROLE}"
      echo "$(date -u --rfc-3339=seconds) - Using pre-configured custom role '${additional_custom_role}' for openshift-image-registry"
      ;;
      openshift-ingress-gcp)
      additional_custom_role="${INGRESS_CUSTOM_ROLE}"
      echo "$(date -u --rfc-3339=seconds) - Using pre-configured custom role '${additional_custom_role}' for openshift-ingress-operator"
      ;;
      openshift-machine-api-gcp)
      additional_custom_role="${MACHINE_API_CUSTOM_ROLE}"
      echo "$(date -u --rfc-3339=seconds) - Using pre-configured custom role '${additional_custom_role}' for openshift-machine-api"
      ;;
      *)
      echo "$(date -u --rfc-3339=seconds) - ERROR: Failed to determine the required custom role by 'spec.providerSpec.permissions'"
      cat "${creds_requests_dir}/${yaml_filename}"
      exit 1
      ;;
    esac
    cmd="gcloud iam roles describe $(basename ${additional_custom_role}) --project=${GOOGLE_PROJECT_ID}"
    run_command "${cmd}"
    cmd="yq-go r ${creds_requests_dir}/${yaml_filename} spec.providerSpec.permissions"
    run_command "${cmd}"
    roles=("${roles[@]}" "${additional_custom_role}")
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
