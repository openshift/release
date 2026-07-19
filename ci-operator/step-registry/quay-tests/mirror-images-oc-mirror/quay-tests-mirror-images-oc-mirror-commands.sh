#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
cp /var/run/ci-credentials/registry/.dockerconfigjson /tmp/pull-secret.json
export REGISTRY_AUTH_FILE=/tmp/pull-secret.json
mkdir -p "${XDG_RUNTIME_DIR}"

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

# "oc-mirror --v2 version" returns "v0.0.0-unknown" in < ocp 4.18
# oc major version is same as oc-mirror major version,
# use oc version to check the oc-mirror version
function isPreVersion() {
  local required_ocp_version="$1"
  local isPre version
  version=$(oc version -o json | python3 -c 'import json,sys;j=json.load(sys.stdin);print(j["clientVersion"]["gitVersion"])' | cut -d '.' -f1,2)
  echo "get oc version: ${version}"
  isPre=0
  if [ -n "${version}" ] && [ "$(printf '%s\n' "${required_ocp_version}" "${version}" | sort --version-sort | head -n1)" = "${required_ocp_version}" ]; then
    isPre=1
  fi
  return $isPre
}

function check_signed() {
    local digest algorithm hash_value response try max_retries payload="${1}"
    if [[ "${payload}" =~ "@sha256:" ]]; then
        digest="$(echo "${payload}" | cut -f2 -d@)"
        echo "The target image is using digest pullspec, its digest is ${digest}"
    else
        digest="$(oc image info "${payload}" -o json | python3 -c 'import json,sys;j=json.load(sys.stdin);print(j["digest"])')"
        echo "The target image is using tagname pullspec, its digest is ${digest}"
    fi
    algorithm="$(echo "${digest}" | cut -f1 -d:)"
    hash_value="$(echo "${digest}" | cut -f2 -d:)"
    try=0
    max_retries=3
    response=0
    while (( try < max_retries && response != 200 )); do
        echo "Trying #${try}"
        response=$(https_proxy="" HTTPS_PROXY="" curl -L --silent --output /dev/null --write-out %"{http_code}" "https://openshift-mirror-list.ci-systems.workers.dev/pub/openshift-v4/signatures/openshift/release/${algorithm}=${hash_value}/signature-1")
        (( try += 1 ))
        sleep 60
    done
    if (( response == 200 )); then
        echo "${payload} is signed" && return 0
    else
        echo "Seem like ${payload} is not signed" && return 1
    fi
}

# Read OMR host from shared dir
OMR_HOST_NAME=$(cat "${SHARED_DIR}/OMR_HOST_NAME")
MIRROR_REGISTRY_HOST="${OMR_HOST_NAME}:8443"
echo "MIRROR_REGISTRY_HOST: ${MIRROR_REGISTRY_HOST}"

echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
if [[ -z "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

# target release
target_release_image="${MIRROR_REGISTRY_HOST}/${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE#*/}"
target_release_image_repo="${target_release_image%:*}"
target_release_image_repo="${target_release_image_repo%@sha256*}"
echo "target_release_image_repo: ${target_release_image_repo}"

# since ci-operator gives steps KUBECONFIG pointing to cluster under test under some circumstances,
# unset KUBECONFIG to ensure this step always interact with the build farm.
KUBECONFIG="" oc registry login
mkdir -p "${HOME}/.docker"
cp /tmp/pull-secret.json "${HOME}/.docker/config.json"

run_command "which oc"
run_command "oc version --client"

# Create combined pull secret (cluster profile + OMR hardcoded credential)
combined_pull_secret_tmp=$(mktemp)
registry_cred="cXVheTpwYXNzd29yZA=="
python3 -c 'import json,sys;j=json.load(sys.stdin);a=j["auths"];a["'"${MIRROR_REGISTRY_HOST}"'"]={"auth":"'"${registry_cred}"'"};j["auths"]=a;print(json.dumps(j))' < "${CLUSTER_PROFILE_DIR}/pull-secret" > "${combined_pull_secret_tmp}"

# Extract the full OCP version from the target release
ocp_full_version=$(oc adm release info --registry-config "${combined_pull_secret_tmp}" "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" -o jsonpath='{.metadata.version}')
echo "Target OCP version: ${ocp_full_version}"

# Detect architecture for oc-mirror download
ARCH=$(uname -m)
case ${ARCH} in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
esac

# Determine which oc-mirror version to download
# Nightly/CI/pre-release builds aren't published to mirror.openshift.com
if [[ "${ocp_full_version}" =~ ^([0-9]+\.[0-9]+)\. ]]; then
    ocp_minor_version="${BASH_REMATCH[1]}"
    if [[ "${ocp_full_version}" =~ (nightly|ci|rc|ec) ]]; then
        # For nightly/CI/RC/EC builds, try stable-X.Y channel, fall back to latest
        stable_channel_url="https://mirror.openshift.com/pub/openshift-v4/${ARCH}/clients/ocp/stable-${ocp_minor_version}/"
        stable_exists=false
        max_retries=3
        retry_count=0
        while [[ ${retry_count} -lt ${max_retries} ]]; do
            if curl -sf --head --connect-timeout 10 "${stable_channel_url}" >/dev/null 2>&1; then
                stable_exists=true
                break
            fi
            ((retry_count++))
            if [[ ${retry_count} -lt ${max_retries} ]]; then
                echo "Stable channel probe attempt ${retry_count} failed, retrying..."
                sleep 2
            fi
        done

        if [[ "${stable_exists}" == "true" ]]; then
            oc_mirror_version="stable-${ocp_minor_version}"
            echo "Using oc-mirror from stable-${ocp_minor_version} channel (target is pre-release build)"
        else
            oc_mirror_version="latest"
            echo "Using oc-mirror from latest channel (stable-${ocp_minor_version} not yet available)"
        fi
    else
        # For GA releases, use exact version
        oc_mirror_version="${ocp_full_version}"
        echo "Using oc-mirror version ${ocp_full_version} (target is GA release)"
    fi
else
    # Fallback to latest if version format is unexpected
    oc_mirror_version="latest"
    echo "Warning: Unexpected version format '${ocp_full_version}', using latest oc-mirror"
fi

# Download oc-mirror from mirror.openshift.com
oc_mirror_download_dir=$(mktemp -d)
pushd "${oc_mirror_download_dir}"
echo "Downloading oc-mirror from https://mirror.openshift.com/pub/openshift-v4/${ARCH}/clients/ocp/${oc_mirror_version}/"
curl -fL --retry 5 --connect-timeout 30 -o oc-mirror.tar.gz \
    "https://mirror.openshift.com/pub/openshift-v4/${ARCH}/clients/ocp/${oc_mirror_version}/oc-mirror.tar.gz"

# Verify integrity of the downloaded tarball
echo "Verifying oc-mirror.tar.gz integrity..."
curl -fL --retry 5 --connect-timeout 30 -o sha256sum.txt \
    "https://mirror.openshift.com/pub/openshift-v4/${ARCH}/clients/ocp/${oc_mirror_version}/sha256sum.txt"
grep "oc-mirror.tar.gz" sha256sum.txt | sha256sum -c - || {
    echo "ERROR: oc-mirror.tar.gz checksum verification failed"
    exit 1
}
echo "Checksum verification passed"

tar -xzf oc-mirror.tar.gz
chmod +x oc-mirror
oc_mirror_bin="${oc_mirror_download_dir}/oc-mirror"
popd

run_command "'${oc_mirror_bin}' version --output=yaml"

oc_mirror_dir=$(mktemp -d)
pushd "${oc_mirror_dir}"
new_pull_secret="${oc_mirror_dir}/new_pull_secret"

# Reuse the combined pull secret created earlier
cp "${combined_pull_secret_tmp}" "${new_pull_secret}"
rm -f "${combined_pull_secret_tmp}"
oc registry login --to "${new_pull_secret}"

# Set up ImageSetConfiguration
image_set_config="image_set_config.yaml"
cat <<END | tee "${image_set_config}"
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    release: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}
END

# Determine --ignore-release-signature flag
extra_flags=""
if ! isPreVersion "4.19" && ! check_signed "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" ; then
    extra_flags="--ignore-release-signature"
    echo "Will use --ignore-release-signature for unsigned release"
fi

# Set up auth for oc-mirror
# oc-mirror only respects ~/.docker/config.json -> ${XDG_RUNTIME_DIR}/containers/auth.json
mkdir -p "${XDG_RUNTIME_DIR}/containers/"
cp -rf "${new_pull_secret}" "${XDG_RUNTIME_DIR}/containers/auth.json"

unset REGISTRY_AUTH_PREFERENCE


# Build oc-mirror command
mirrorCmd="${oc_mirror_bin} -c ${image_set_config} docker://${target_release_image_repo} --dest-tls-verify=false --v2 --workspace file://${oc_mirror_dir}"

# ref OCPBUGS-56009: add --ignore-release-signature for unsigned releases >= 4.19
if [[ -n "${extra_flags}" ]]; then
    mirrorCmd="${mirrorCmd} ${extra_flags}"
fi

# Execute the oc-mirror command with retry logic
MAX_ATTEMPTS=5
ATTEMPT=0
SUCCESS=false
while [[ "${SUCCESS}" == "false" ]] && (( ATTEMPT++ < MAX_ATTEMPTS )); do
  echo "Mirroring images attempt ${ATTEMPT}/${MAX_ATTEMPTS}..."
  if eval "${mirrorCmd}"; then
    echo "Mirroring images succeeded on attempt ${ATTEMPT}"
    SUCCESS=true
  else
    echo "Mirroring images attempt ${ATTEMPT} failed, retrying in 120s..."
    sleep 120
  fi
done

if [[ "${SUCCESS}" == "false" ]]; then
  echo "Mirroring images failed after ${MAX_ATTEMPTS} attempts"
  exit 1
fi

# Process oc-mirror output
result_folder="${oc_mirror_dir}/working-dir"
idms_file="${result_folder}/cluster-resources/idms-oc-mirror.yaml"
itms_file="${result_folder}/cluster-resources/itms-oc-mirror.yaml"

if [ ! -s "${idms_file}" ]; then
    echo "${idms_file} not found, exit..."
    exit 1
else
    run_command "cat '${idms_file}'"
    run_command "cp -rf '${idms_file}' ${SHARED_DIR}"
fi

if [ -s "${itms_file}" ]; then
    echo "${itms_file} found"
    run_command "cat '${itms_file}'"
    run_command "cp -rf '${itms_file}' ${SHARED_DIR}"
fi

# Convert IDMS imageDigestMirrors to install-config imageDigestSources format
install_config_icsp_patch="${SHARED_DIR}/install-config-icsp.yaml.patch"
python3 -c '
import yaml, sys

with open("'"${idms_file}"'") as f:
    docs = list(yaml.safe_load_all(f))

all_mirrors = []
for doc in docs:
    if doc and "spec" in doc and "imageDigestMirrors" in doc["spec"]:
        all_mirrors.extend(doc["spec"]["imageDigestMirrors"])

output = {"imageDigestSources": []}
for m in all_mirrors:
    entry = {"source": m["source"], "mirrors": m["mirrors"]}
    output["imageDigestSources"].append(entry)

print(yaml.dump(output, default_flow_style=False))
' > "${install_config_icsp_patch}"

echo "install-config-icsp.yaml.patch:"
cat "${install_config_icsp_patch}"

# Clean up
rm -f "${new_pull_secret}"
popd
