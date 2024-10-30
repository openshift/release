#!/bin/bash

set -euo pipefail

export VAULT_ADDR=https://vault.ci.openshift.org

VAULT_TOKEN="${VAULT_TOKEN:-$(vault token lookup --format=json|jq .data.id -r)}"
[[ -z ${VAULT_TOKEN:-} ]] && echo '$VAULT_TOKEN is undefined' && exit 1

RAW_VAULT_OIDC_VALUES="$(kubectl --context=app.ci get secret -n dex vault-secret -o json)"
VAULT_OIDC_CLIENT_ID="$(echo $RAW_VAULT_OIDC_VALUES|jq '.data["vault-id"]' -r|base64 -d)"
VAULT_OIDC_CLIENT_SECRET="$(echo $RAW_VAULT_OIDC_VALUES|jq '.data["vault-secret"]' -r|base64 -d)"


# Enable kv backend
vault secrets list|grep -q kv || vault secrets enable -version=2 kv

# Enable and configure kubernetes and OIDC auth
vault auth list|grep -q kubernetes ||  vault auth enable kubernetes
VAULT_KUBE_TOKEN="$(oc --context=app.ci serviceaccounts -n vault get-token vault)"
APP_CI_CA_CERT="$(oc --context=app.ci get configmap -n kube-public kube-root-ca.crt -o json|jq '.data["ca.crt"]' -r)"
vault write auth/kubernetes/config \
    token_reviewer_jwt="${VAULT_KUBE_TOKEN}" \
    kubernetes_host=https://kubernetes.default.svc.cluster.local \
    kubernetes_ca_cert="${APP_CI_CA_CERT}" \
    issuer="$(oc --context=app.ci get authentication.config cluster -o template="{{ .spec.serviceAccountIssuer }}")"

vault auth list |grep -q oidc || vault auth enable oidc
echo "Configuring OIDC"
vault write auth/oidc/config -<<EOH
{
  "oidc_client_id": "$VAULT_OIDC_CLIENT_ID",
  "oidc_client_secret": "$VAULT_OIDC_CLIENT_SECRET",
  "default_role": "oidc_default_role",
  "oidc_discovery_url": "https://idp.ci.openshift.org"
}
EOH

echo "Configuring OIDC role"
vault write auth/oidc/role/oidc_default_role \
  allowed_redirect_uris="https://vault.ci.openshift.org/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback" \
  token_ttl=3600 \
  token_max_ttl=3600 \
  oidc_scopes="profile" \
  user_claim="preferred_username"

# Set this as default, ref https://support.hashicorp.com/hc/en-us/articles/360001922527-Configuring-a-Default-UI-Auth-Method
vault write sys/auth/oidc/tune listing_visibility="unauth"

# Extend the default policy to allow everyone to manage secrets at
# secrets/personal/{{ldap_name}}
OIDC_ACCESSOR_ID="$(vault auth list -format=json|jq '.["oidc/"].accessor' -r)"

echo "Configuring default policy"
vault policy write default -<<EOH
path "auth/token/lookup-self" {
    capabilities = ["read"]
}

# Allow tokens to renew themselves
path "auth/token/renew-self" {
    capabilities = ["update"]
}

# Allow tokens to revoke themselves
path "auth/token/revoke-self" {
    capabilities = ["update"]
}

# Allow a token to look up its own capabilities on a path
path "sys/capabilities-self" {
    capabilities = ["update"]
}

# Allow a token to look up its own entity by id or name
path "identity/entity/id/{{identity.entity.id}}" {
  capabilities = ["read"]
}
path "identity/entity/name/{{identity.entity.name}}" {
  capabilities = ["read"]
}


# Allow a token to look up its resultant ACL from all policies. This is useful
# for UIs. It is an internal path because the format may change at any time
# based on how the internal ACL features and capabilities change.
path "sys/internal/ui/resultant-acl" {
    capabilities = ["read"]
}

# Allow a token to renew a lease via lease_id in the request body; old path for
# old clients, new path for newer
path "sys/renew" {
    capabilities = ["update"]
}
path "sys/leases/renew" {
    capabilities = ["update"]
}

# Allow looking up lease properties. This requires knowing the lease ID ahead
# of time and does not divulge any sensitive information.
path "sys/leases/lookup" {
    capabilities = ["update"]
}

# Allow a token to manage its own cubbyhole
path "cubbyhole/*" {
    capabilities = ["create", "read", "update", "delete", "list"]
}

# Allow a token to wrap arbitrary values in a response-wrapping token
path "sys/wrapping/wrap" {
    capabilities = ["update"]
}

# Allow a token to look up the creation time and TTL of a given
# response-wrapping token
path "sys/wrapping/lookup" {
    capabilities = ["update"]
}

# Allow a token to unwrap a response-wrapping token. This is a convenience to
# avoid client token swapping since this is also part of the response wrapping
# policy.
path "sys/wrapping/unwrap" {
    capabilities = ["update"]
}

# Allow general purpose tools
path "sys/tools/hash" {
    capabilities = ["update"]
}
path "sys/tools/hash/*" {
    capabilities = ["update"]
}

# Allow checking the status of a Control Group request if the user has the
# accessor
path "sys/control-group/request" {
    capabilities = ["update"]
}
EOH

# Create the secret generator policy and role
vault policy write secret-generator -<<EOH
path "kv/data/dptp/*" {
  capabilities = ["create", "update", "read"]
}

path "kv/metadata/dptp/*" {
  capabilities = ["list"]
}
EOH
vault write auth/kubernetes/role/secret-generator \
    bound_service_account_names=secret-generator \
    bound_service_account_namespaces=ci \
    policies=secret-generator \
    ttl=1h

# Create the secret bootstrap policy and role
vault policy write secret-bootstrap -<<EOH
path "kv/data/*" {
  capabilities = ["read"]
}

path "kv/metadata/*" {
  capabilities = ["list"]
}
EOH
vault write auth/kubernetes/role/secret-bootstrap \
    bound_service_account_names=secret-bootstrap \
    bound_service_account_namespaces=ci \
    policies=secret-bootstrap \
    ttl=1h

vault policy write release-controller -<<EOH
path "kv/data/dptp/openshift-ci-release-signature-signer" {
  capabilities = ["create", "update", "read"]
}

path "kv/data/dptp/openshift-ci-release-signature-publisher" {
  capabilities = ["create", "update", "read"]
}

# Doesn't allow access to the actual data and we can not give
# list for individual names
path "kv/metadata/dptp/*" {
  capabilities = ["list"]
}

# Allows getting the old revisions
path "kv/metadata/dptp/openshift-ci-release-signature-*" {
  capabilities = ["read"]
}
EOH

getUserIDByLDAPName() {
  curl -Ss --fail -H "X-vault-token: ${VAULT_TOKEN}" "$VAULT_ADDR/v1/identity/entity/id?list=true" \
   |jq --arg user "$1" '.data.key_info|to_entries[]|select(.value.aliases[0].name == $user)|.key' -r
}

# unused but left for documentation purposes
upsertUser() {
  user=$1
  if [[ -n "$(getUserIDByLDAPName $1)" ]]; then echo "User $user already exists, skipping create"; return; fi
  oidc_acessor="$(vault auth list --format=json |jq '."oidc/".accessor' -r)"
  create_response="$(vault write -format=json identity/entity name="$user" policies="default")"
  id="$(echo $create_response|jq .data.id -r)"
  vault write identity/entity-alias name="$user" canonical_id="$id" mount_accessor="$oidc_acessor" >/dev/null
  echo "Successfully created user $user"
}

getUserIDByLDAPName brawilli
vault write identity/group name="release-controller" policies="release-controller" member_entity_ids="$(getUserIDByLDAPName brawilli)"

vault policy write vault-secret-collection-manager -<<EOH
path "identity/group" {
  capabilities = ["create", "update"]
}

path "identity/group/*" {
  capabilities = ["read", "list", "create", "update", "delete"]
}

path "sys/policies/acl/*" {
  capabilities = ["read", "list", "create", "update", "delete"]
}

path "sys/auth" {
  capabilities = ["read"]
}

path "identity/entity-alias/id" {
  capabilities = ["list"]
}

path "identity/entity/id"  {
  capabilities = ["list"]
}

path "identity/entity" {
  capabilities = ["create", "update"]
}

path "identity/entity-alias" {
  capabilities = ["create", "update"]
}

path "identity/entity/id/*"  {
  capabilities = ["read"]
}

path "identity/entity/name/*"  {
  capabilities = ["read"]
}

path "kv/metadata/selfservice/*" {
  capabilities = ["list", "delete"]
}

# We create a marker item and create is
# actually upsert, so needs both read and
# create
path "kv/data/selfservice/*" {
  capabilities = ["create", "read"]
}
EOH
vault write auth/kubernetes/role/vault-secret-collection-manager \
  bound_service_account_names=vault-secret-collection-manager \
  bound_service_account_namespaces=ci \
  policies=vault-secret-collection-manager \
  ttl=1h

vault policy write vault-subpath-proxy -<<EOH
path "kv/data/*" {
  capabilities = ["read"]
}

path "kv/metadata/*" {
  capabilities = ["list"]
}
EOH
vault write auth/kubernetes/role/vault-subpath-proxy \
  bound_service_account_names=vault \
  bound_service_account_namespaces=vault \
  policies=vault-subpath-proxy \
  ttl=1h

# Make dptp members admins
echo "Setting up admin policy"
vault policy write admin -<<EOF
path "*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
EOF

# Vault auth plugins are an abstration above the real identity and create an alias. Getting from
# that alias back to the identity id which is the thing we need to set up a group is non-trivial.
echo "Finding ids for dptp members"
dptp_member_aliases='[
  "hongkliu",
  "nmoraiti",
  "sgoeddel",
  "jupierce",
  "bechen",
  "jguzik",
  "dgemoli",
  "psalajov",
  "dmistry",
  "prucek",
  "hvidosil"
 ]'
dptp_ids="$(curl -Ss --fail -H "X-vault-token: ${VAULT_TOKEN}" "$VAULT_ADDR/v1/identity/entity/id?list=true" \
            |jq \
                --argjson dptp_members "$dptp_member_aliases" \
                '[.data.key_info|to_entries[]|select([.value.aliases[0].name] | inside($dptp_members))|.key]|@csv' -rc \
            |tr -d '"')"

echo "Setting up group for dptp"
vault write identity/group name="dptp" policies="admin" member_entity_ids="$dptp_ids"
