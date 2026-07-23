#!/usr/bin/env bash

set -euo pipefail

# brew.registry.redhat.io auth
reg_brew_user="$(jq -r '.user' '/var/run/vault/mirror-registry/registry_brew.json')"
reg_brew_password="$(jq -r '.password' '/var/run/vault/mirror-registry/registry_brew.json')"
brew_registry_auth="$(echo -n "${reg_brew_user}:${reg_brew_password}" | base64 -w 0)"

# registry.stage.redhat.io auth
stage_auth_user="$(jq -r '.user' '/var/run/vault/mirror-registry/registry_stage.json')"
stage_auth_password="$(jq -r '.password' '/var/run/vault/mirror-registry/registry_stage.json')"
stage_registry_auth="$(echo -n "${stage_auth_user}:${stage_auth_password}" | base64 -w 0)"

# quay.io/openshift-qe-optional-operators auth
optional_auth_user="$(jq -r '.user' '/var/run/vault/mirror-registry/registry_quay.json')"
optional_auth_password="$(jq -r '.password' '/var/run/vault/mirror-registry/registry_quay.json')"
qe_registry_auth="$(echo -n "${optional_auth_user}:${optional_auth_password}" | base64 -w 0)"

# quay.io/openshifttest auth
openshifttest_auth_user="$(jq -r '.user' '/var/run/vault/mirror-registry/registry_quay_openshifttest.json')"
openshifttest_auth_password="$(jq -r '.password' '/var/run/vault/mirror-registry/registry_quay_openshifttest.json')"
openshifttest_registry_auth="$(echo -n "${openshifttest_auth_user}:${openshifttest_auth_password}" | base64 -w 0)"

# acr auth
acr_login_server="$(</var/run/vault/preservehypershiftaks/loginserver)"
acr_user="$(</var/run/vault/preservehypershiftaks/username)"
acr_password="$(</var/run/vault/preservehypershiftaks/password)"
acr_auth="$(echo -n "${acr_user}:${acr_password}" | base64 -w 0)"

echo "Merging extra auth info into the existing pull secret"
extra_auth="{\"brew.registry.redhat.io\": {\"auth\": \"${brew_registry_auth}\"},\
\"registry.stage.redhat.io\": {\"auth\": \"${stage_registry_auth}\"},\
\"quay.io/openshift-qe-optional-operators\": {\"auth\": \"${qe_registry_auth}\"},\
\"quay.io/openshifttest\": {\"auth\": \"${openshifttest_registry_auth}\"},\
\"${acr_login_server}\": {\"auth\": \"${acr_auth}\"}}"
pull_secret_path="/var/run/vault/ci-pull-credentials/.dockerconfigjson"
jq --argjson a "$extra_auth" '.auths |= . + $a' "$pull_secret_path" > "${SHARED_DIR}"/hypershift-pull-secret
