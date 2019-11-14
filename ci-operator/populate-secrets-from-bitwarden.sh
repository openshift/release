#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

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

# Bugzilla API keys are stored as a text field named "API Key"
login="openshift-bugzilla-robot"
update_secret generic "bugzilla-credentials-${login}" "$( format_field_value "${login}" "API Key" "api" )"

# Jenkins credentials are stored as separate items in Bitwarden,
# with the token recorded as the password for the account
for master in "ci.openshift.redhat.com" "kata-jenkins-ci.westus2.cloudapp.azure.com"; do
	update_secret generic "jenkins-credentials-${master}" "$( format_field "${master}" ".login.password" "password" )"
done

# Client certificates for the ci.dev Jenkins
# master are stored in a special set of fields
master="ci.dev.openshift.redhat.com"
update_secret generic "jenkins-credentials-${master}"            \
	"$( format_field "${master}" ".login.password" "password" )" \
	"$( format_attachment "${master}" cert.pem )"                \
	"$( format_attachment "${master}" key.pem )"                 \
	"$( format_attachment "${master}" ca.pem )"

# OAuth tokens for GitHub are stored as a text field named
# "GitHub OAuth Token" on login credential items for each robot.
for login in "openshift-bot" "openshift-build-robot" "openshift-cherrypick-robot" "openshift-ci-robot" "openshift-merge-robot" "openshift-publish-robot"; do
	update_secret generic "github-credentials-${login}" "$( format_field_value "${login}" "GitHub OAuth Token" "oauth" )"
done

# openshift-publish-robot also has a token that grants read-only
# access to private repositories.
update_secret generic "private-git-cloner" "$( format_field_value "openshift-publish-robot" private-git-cloner "oauth" )"

# Configuration for Slack ci-chat-bot is stored under "Token"
# and the key value is "token" in the secret
update_secret generic ci-chat-bot-slack-token "$( format_field_value ci-chat-bot-slack-token "Token" "token" )"

# Configuration for api_url, which is for slack incoming hooks and can be used eg in prometheus alert-manager, is stored under "url"
# and the key value is "url" in the secret
update_secret generic ci-slack-api-url "$( format_field_value ci-slack-api-url "url" "url" )"

# Configuration for GitHub OAuth Apps are stored
# as an opaque field "Client Configuration"
update_secret generic github-app-credentials "$( format_field_value prow.svc.ci.openshift.org "Client Configuration" "config.json" )"

# Cookie secret to encrypt frontend and backend
# communication is stored in the "Cookie" field
update_secret generic cookie "$( format_field_value prow.svc.ci.openshift.org Cookie "cookie" )"

# HMAC token for encrypting GitHub webhook payloads
# is stored in the "HMAC Token" field
update_secret generic github-webhook-credentials "$( format_field_value hmac "HMAC Token" "hmac" )"

# DeploymentConfig token is used to auth trigger events
# for DeploymentConfigs from GitHub
update_secret generic github-deploymentconfig-trigger "$( format_field_value github-deploymentconfig-webhook-token "Token" "WebHookSecretKey" )"

# Unsplash API key is stored as a text field named "API Key"
# It's used for the "goose" prow plugin
update_secret generic "unsplash-api-key"         \
	"$( format_field_value "unsplash.com" "API Key" "api-key" )"

# Credentials for GCE service accounts are stored
# as an attachment on each distinct credential
for account in "aos-pubsub-subscriber" "ci-vm-operator" "gcs-publisher" "gcs-tide-publisher" "gcs-private"; do
	update_secret generic "gce-sa-credentials-${account}" "$( format_attachment "${account}" credentials.json service-account.json )"
done

# Some GCE serviceaccounts also have SSH keys
for account in "aos-serviceaccount" "jenkins-ci-provisioner"; do
	update_secret generic "gce-sa-credentials-${account}"      \
		"$( format_attachment "${account}" credentials.json service-account.json )" \
		"$( format_attachment "${account}" ssh-privatekey )"   \
		"$( format_attachment "${account}" ssh-publickey )"
done

# Credentials for registries are stored as
# separate fields on individual items
for registry in "docker.io" "quay.io" "quay.io/openshift-knative" "quay.io/openshiftio" "quay.io/openshift-pipeline" "quay.io/codeready-toolchain" "quay.io/operator-manifests"; do
	update_secret generic "registry-push-credentials-${registry//\//\-}" $( format_field_value "${registry}" "Push Credentials" "config.json" )
	# we want to be able to build and push out to registries
	oc secrets link builder "registry-push-credentials-${registry//\//\-}"
done

registry="quay.io"
update_secret generic "registry-pull-credentials-${registry}" $( format_field_value "${registry}" "Pull Credentials" "config.json" )
update_secret generic "ci-pull-credentials" --type=kubernetes.io/dockerconfigjson $( format_field_value "${registry}" "Pull Credentials" ".dockerconfigjson" )

update_secret generic "operator-manifests-test-credentials"     \
	"$( format_attachment "operator-manifests" test.env.yaml )" \
	"$( format_attachment "operator-manifests" quay-env.txt )"

# Cluster credentials aggregate multiple items
# of information for easy consumption by tests
target_cloud="aws"
update_secret generic "cluster-secrets-${target_cloud}"                         \
	"$( format_attachment "quay.io" pull-secret )"                              \
	"$( format_attachment "insights-ci-account" insights-live.yaml )"            \
	"$( format_attachment "jenkins-ci-iam" .awscred )"                          \
	"$( format_attachment "jenkins-ci-iam" ssh-privatekey )"                    \
	"$( format_attachment "mirror.openshift.com" cert-key.pem ops-mirror.pem )" \
	"$( format_attachment "jenkins-ci-iam" ssh-publickey )"

target_cloud="gcp"
update_secret generic "cluster-secrets-${target_cloud}"                         \
	"$( format_attachment "quay.io" pull-secret )"                              \
	"$( format_attachment "insights-ci-account" insights-live.yaml )"            \
	"$( format_attachment "jenkins-ci-provisioner" credentials.json gce.json )" \
	"$( format_attachment "jenkins-ci-provisioner" ssh-privatekey )"            \
	"$( format_attachment "jenkins-ci-provisioner" ssh-publickey )"             \
	"$( format_attachment "mirror.openshift.com" cert-key.pem ops-mirror.pem )" \
	"$( format_field_value telemeter "Telemeter Token" "telemeter-token" )"

target_cloud="openstack"
update_secret generic "cluster-secrets-${target_cloud}"              \
	"$( format_attachment "quay.io" pull-secret )"               \
	"$( format_attachment "openstack" clouds.yaml )"                 \
	"$( format_attachment "insights-ci-account" insights-live.yaml )" \
	"$( format_attachment "jenkins-ci-provisioner" ssh-privatekey )" \
	"$( format_attachment "jenkins-ci-provisioner" ssh-publickey )"

target_cloud="vsphere"
update_secret generic "cluster-secrets-${target_cloud}"          \
	"$( format_attachment "quay.io" pull-secret )"               \
	"$( format_attachment "insights-ci-account" insights-live.yaml )" \
	"$( format_attachment "jenkins-ci-iam" .awscred )"           \
	"$( format_attachment "jenkins-ci-iam" ssh-privatekey )"     \
	"$( format_attachment "jenkins-ci-iam" ssh-publickey )"      \
	"$( format_attachment "vsphere-credentials" secret.auto.tfvars )"

target_cloud="metal"
update_secret generic "cluster-secrets-${target_cloud}"                  \
	"$( format_attachment "quay.io" pull-secret )"                       \
	"$( format_attachment "insights-ci-account" insights-live.yaml )"     \
	"$( format_attachment "jenkins-ci-iam" .awscred )"                   \
	"$( format_attachment "jenkins-ci-iam" ssh-privatekey )"             \
	"$( format_attachment "jenkins-ci-iam" ssh-publickey )"              \
	"$( format_attachment "packet.net" .packetcred )"                    \
	"$( format_attachment "packet.net" client.crt matchbox-client.crt )" \
	"$( format_attachment "packet.net" client.key matchbox-client.key )"

target_cloud="azure"
update_secret generic "cluster-secrets-${target_cloud}"                                 \
	"$( format_attachment "quay.io" pull-secret )"                                      \
	"$( format_attachment "os4-installer.openshift-ci.azure" osServicePrincipal.json )" \
	"$( format_attachment "jenkins-ci-iam" ssh-privatekey )"                            \
	"$( format_attachment "jenkins-ci-iam" ssh-publickey )"

# DSNs for tools reporting failures to Sentry
update_secret generic "sentry-dsn" "$( format_field_value "sentry" "ci-operator" "ci-operator" )"

# codecov.io tokens we store for teams
update_secret generic "redhat-developer-service-binding-operator-codecov-token" "$( format_field_value "codecov-tokens" redhat-developer-service-binding-operator token )"

# collects all the secrets for build farm
update_secret generic "build-farm-credentials" \
	"$( format_field_value build_farm_01_cluster "github_client_secret" "build01_github_client_secret" )" \
	"$( format_attachment "build_farm" build01_ci_reg_auth_value.txt )" \
	"$( format_attachment "build_farm" sa.deck.build01.config )" \
	"$( format_attachment "build_farm" sa.hook.build01.config )" \
	"$( format_attachment "build_farm" sa.plank.build01.config )" \
	"$( format_attachment "build_farm" sa.sinker.build01.config )" \
	"$( format_attachment "build_farm" sa.kubeconfig )"

# collects all the secrets for ci-operator
update_secret generic "apici-ci-operator-credentials" \
	"$( format_attachment "build_farm" sa.ci-operator.apici.config )"

# Configuration for the .git-credentials used by the release controller to clone
# private repositories to generate changelogs
oc -n "ci-release" create secret generic "git-credentials" "--from-literal=.git-credentials=https://openshift-bot:$( field_value "openshift-bot" "GitHub OAuth Token" "oauth" )@github.com" --dry-run -o yaml | oc apply -f -
oc -n "ci-release" label secret "git-credentials" "ci.openshift.io/managed=true" --overwrite

# The private key here is used to mirror content from the ops mirror
update_secret generic "mirror.openshift.com" "$( format_attachment "mirror.openshift.com" cert-key.pem ops-mirror.pem )"

#https://jira.coreos.com/browse/DPP-2164
update_secret generic "aws-openshift-llc-account-credentials" \
	"$( format_attachment "AWS ci-longlivedcluster-bot" .awscred )"
