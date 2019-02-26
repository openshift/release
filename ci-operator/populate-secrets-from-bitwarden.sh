#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

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

if [[ -z "${BW_SESSION:-}" ]]; then
	echo "[WARNING] Ensure you have an active BitWarden session and provide the session token with \$BW_SESSION"
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

# merge all pull secret credentials into a single json
# object
function merge_pull_secrets() {
	local quay_io redhat_io
	quay_io="$(get_field_value quay.io 'Pull Credentials')"
	redhat_io="$(<"$(get_attachment registry.redhat.io pull_secret)")"
	printf '%s\n' "${quay_io}" "${redhat_io}" \
		| jq --slurp --compact-output 'reduce .[] as $x ({}; . * $x)'
}

function update_secret() {
    oc create secret "$@" --dry-run -o yaml | oc apply -f -
}

# Jenkins credentials are stored as separate items in Bitwarden,
# with the token recorded as the password for the account
for master in "ci.openshift.redhat.com" "kata-jenkins-ci.westus2.cloudapp.azure.com"; do
	update_secret generic "jenkins-credentials-${master}" "$( format_field "${master}" ".login.password" "password" )"
	oc label secret "jenkins-credentials-${master}" "ci.openshift.io/managed=true"
done

# Client certificates for the ci.dev Jenkins
# master are stored in a special set of fields
master="ci.dev.openshift.redhat.com"
update_secret generic "jenkins-credentials-${master}"            \
	"$( format_field "${master}" ".login.password" "password" )" \
	"$( format_attachment "${master}" cert.pem )"                \
	"$( format_attachment "${master}" key.pem )"                 \
	"$( format_attachment "${master}" ca.pem )"
oc label secret "jenkins-credentials-${master}" "ci.openshift.io/managed=true"

# OAuth tokens for GitHub are stored as a text field named
# "GitHub OAuth Token" on login credential items for each robot.
for login in "openshift-bot" "openshift-build-robot" "openshift-cherrypick-robot" "openshift-ci-robot" "openshift-merge-robot" "openshift-publish-robot"; do
	update_secret generic "github-credentials-${login}" "$( format_field_value "${login}" "GitHub OAuth Token" "oauth" )"
	oc label secret "github-credentials-${login}" "ci.openshift.io/managed=true"
done

# Configuration for Slack ci-chat-bot is stored under "Token"
# and the key value is "token" in the secret
update_secret generic ci-chat-bot-slack-token "$( format_field_value ci-chat-bot-slack-token "Token" "token" )"
oc label secret "ci-chat-bot-slack-token" "ci.openshift.io/managed=true"

# Configuration for GitHub OAuth Apps are stored
# as an opaque field "Client Configuration"
update_secret generic github-app-credentials "$( format_field_value deck-ci.svc.ci.openshift.org "Client Configuration" "config.json" )"
oc label secret "github-app-credentials" "ci.openshift.io/managed=true"

# Cookie secret to encrypt frontend and backend
# communication is stored in the "Cookie" field
update_secret generic cookie "$( format_field_value deck-ci.svc.ci.openshift.org Cookie "cookie" )"
oc label secret "cookie" "ci.openshift.io/managed=true"

# HMAC token for encrypting GitHub webhook payloads
# is stored in the "HMAC Token" field
update_secret generic github-webhook-credentials "$( format_field_value hmac "HMAC Token" "hmac" )"
oc label secret "github-webhook-credentials" "ci.openshift.io/managed=true"

# DeploymentConfig token is used to auth trigger events
# for DeploymentConfigs from GitHub
update_secret generic github-deploymentconfig-trigger "$( format_field_value github-deploymentconfig-webhook-token "Token" "WebHookSecretKey" )"
oc label secret "github-deploymentconfig-trigger" "ci.openshift.io/managed=true"

# Credentials for GCE service accounts are stored
# as an attachment on each distinct credential
for account in "aos-pubsub-subscriber" "ci-vm-operator" "gcs-publisher"; do
	update_secret generic "gce-sa-credentials-${account}" "$( format_attachment "${account}" credentials.json service-account.json )"
	oc label secret "gce-sa-credentials-${account}" "ci.openshift.io/managed=true"
done


# Some GCE serviceaccounts also have SSH keys
for account in "aos-serviceaccount" "jenkins-ci-provisioner"; do
	update_secret generic "gce-sa-credentials-${account}"      \
		"$( format_attachment "${account}" credentials.json service-account.json )" \
		"$( format_attachment "${account}" ssh-privatekey )"   \
		"$( format_attachment "${account}" ssh-publickey )"
	oc label secret "gce-sa-credentials-${account}" "ci.openshift.io/managed=true"
done

# Credentials for registries are stored as
# separate fields on individual items
for registry in "docker.io" "quay.io"; do
	update_secret generic "registry-push-credentials-${registry}" $( format_field_value "${registry}" "Push Credentials" "config.json" )
	oc label secret "registry-push-credentials-${registry}" "ci.openshift.io/managed=true"
	# we want to be able to build and push out to registries
	oc secrets link builder "registry-push-credentials-${registry}"
done

registry="quay.io"
update_secret generic "registry-pull-credentials-${registry}" $( format_field_value "${registry}" "Pull Credentials" "config.json" )
oc label secret "registry-pull-credentials-${registry}" "ci.openshift.io/managed=true"

# Cluster credentials aggregate multiple items
# of information for easy consumption by tests
target_cloud="aws"
update_secret generic "cluster-secrets-${target_cloud}"                \
	--from-literal=pull-secret="$(merge_pull_secrets)"                   \
	"$( format_attachment "jenkins-ci-iam" .awscred )"                   \
	"$( format_attachment "jenkins-ci-iam" ssh-privatekey )"             \
	"$( format_attachment "jenkins-ci-iam" ssh-publickey )"
oc label secret "cluster-secrets-${target_cloud}" "ci.openshift.io/managed=true"

target_cloud="gcp"
update_secret generic "cluster-secrets-${target_cloud}"                       \
	--from-literal=pull-secret="$(merge_pull_secrets)"                          \
	"$( format_attachment "jenkins-ci-provisioner" credentials.json gce.json )" \
	"$( format_attachment "jenkins-ci-provisioner" ssh-privatekey )"            \
	"$( format_attachment "jenkins-ci-provisioner" ssh-publickey )"             \
	"$( format_attachment "mirror.openshift.com" cert-key.pem ops-mirror.pem )" \
	"$( format_field_value telemeter "Telemeter Token" "telemeter-token" )"
oc label secret "cluster-secrets-${target_cloud}" "ci.openshift.io/managed=true"
