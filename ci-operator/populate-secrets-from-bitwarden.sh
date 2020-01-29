#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# 20200122: This script is deprecated. Use ../core-services/ci-secret-bootstrap/_config.yaml instead.

# This script uses a connection to Bitwarden to populate k8s secrets used for
# the OKD CI infrastructure. To use this script, first get the BitWarden CLI at:
# https://help.bitwarden.com/article/cli/#download--install
# Then, log in to create a session:
#   $ BW_SESSION="$( bw login username@company.com password --raw )"
# Pass that environment variable to this script so that it can use the session.
#
# WARNING: BitWarden sessions are sticky -- if changes have occurred to the
#          content of the BitWarden vault after your current session was started,
#          you will need to create a new session to be able to view those changes.

CURRENT_OC_CONTEXT=$(oc config current-context)
readonly CURRENT_OC_CONTEXT
OC_PROJECT=$(echo ${CURRENT_OC_CONTEXT} | cut -d "/" -f1)
readonly OC_PROJECT
OC_CLUSTER=$(echo ${CURRENT_OC_CONTEXT} | cut -d "/" -f2)
readonly OC_CLUSTER
OC_USER=$(echo ${CURRENT_OC_CONTEXT} | cut -d "/" -f3)
readonly OC_USER

if [[ "${OC_CLUSTER}" != "api-ci-openshift-org:443" ]]; then
	>&2 echo "[ERROR] current cluster ${OC_CLUSTER} is not our ci-cluster ... please run 'oc login https://api.ci.openshift.org' first!"
	exit 1
fi

if [[ "${OC_PROJECT}" != "ci" ]]; then
	>&2 echo "[WARNING] current project ${OC_PROJECT} is not 'ci'!"
fi

if ! oc auth can-i create secrets -n "${OC_PROJECT}" --quiet; then
	>&2 echo "[ERROR] current user ${OC_USER} does not have permission to create secret in ${OC_PROJECT}"
	exit 1
fi

if [[ -z "${BW_SESSION:-}" ]]; then
	>&2 echo "[ERROR] Ensure you have an active BitWarden session and provide the session token with \$BW_SESSION"
	exit 1
fi

# Fetching attachments saves files locally
# that we need to track and clean up. Also,
# we're making a local copy of all of the
# secrets for faster processing, so we need
# to clean that up, too
work_dir="$( mktemp -d )"
cd "${work_dir}"
function cleanup() {
	rm -rf "${work_dir}"
}
trap cleanup EXIT

# BitWarden's `get item $name` invocation does a search on
# the data stored in every secret, so secrets with names
# that are similar to fields in other secrets will not be
# addressable. There is also no way to specifically target
# the item's name field for searching. Therefore, we need
# to dump the list of secrets and search through it explicitly
# using jq. Thankfully, that's not too hard.
secrets="${work_dir}/secrets.json"
bw --session "${BW_SESSION}" list items > "${secrets}"

if [[ "$( jq ". | length" <"${secrets}" )" == 0 ]]; then
	echo "[WARNING] Your active BitWarden session does not have access to secrets. If you created your session before you got access, refresh it by logging out and in again."
	exit 1
fi

# retrieve the value of a top-level field from an item in BitWarden
# and format it in a key-value pair for a k8s secret
function format_field() {
	local item="$1"
	local field="$2"
	local name="${3:-"${item}"}"
	echo "--from-literal=${name}=$( jq ".[] | select(.name == \"${item}\") | ${field}" --raw-output <"${secrets}" )"
}

# retrieve the value of a field from an item in BitWarden
function get_field_value() {
	local item="$1"
	local field="$2"
	jq ".[] | select(.name == \"${item}\") | .fields[] | select(.name == \"${field}\") | .value" --raw-output <"${secrets}"
}

# retrieve the value of a field from an item in BitWarden
# and format it in a key-value pair for a k8s secret
function format_field_value() {
	local item="$1"
	local field="$2"
	local name="${3:-"${item}"}"
	echo "--from-literal=${name}=$(get_field_value "${item}" "${field}")"
}

# retrieve the content of an attachment from an item in BitWarden
function get_attachment() {
	local item="$1"
	local attachment="$2"
	local item_id="$( jq ".[] | select(.name == \"${item}\") | .id" --raw-output <"${secrets}" )"
	local attachment_id="$( jq ".[] | select(.name == \"${item}\") | .attachments[] | select(.fileName == \"${attachment}\") | .id" --raw-output <"${secrets}" )"
	bw --session "${BW_SESSION}" get attachment "${attachment_id}" --itemid "${item_id}" --raw
}

# retrieve the content of an attachment from an item in BitWarden
# and format it in a key-value pair for a k8s secret
function format_attachment() {
	local item="$1"
	local attachment="$2"
	local name="${3:-"${attachment}"}"
	echo "--from-file=${name}=$(get_attachment "${item}" "${attachment}")"
}

function update_secret() {
    local name
    name=$2
    oc create secret "$@" --dry-run -o yaml | oc apply -f -
	oc label secret --overwrite "${name}" "ci.openshift.io/managed=true"
}

# retrieve the value of a field and format it as a string, for
# use when more complex values are required to generate a secret
function field_value() {
	local item="$1"
	local field="$2"
	echo "$( jq ".[] | select(.name == \"${item}\") | .fields[] | select(.name == \"${field}\") | .value" --raw-output <"${secrets}")"
}


# Credentials for registries are stored as
# separate fields on individual items
for registry in "docker.io" "quay.io" "quay.io/openshift-knative" "quay.io/openshiftio" "quay.io/openshift-pipeline" "quay.io/codeready-toolchain" "quay.io/operator-manifests" "quay.io/integr8ly"; do
	# we want to be able to build and push out to registries
	oc secrets link builder "registry-push-credentials-${registry//\//\-}"
done
