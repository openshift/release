#!/bin/bash

set -euo pipefail

export VAULT_ADDR=https://vault.ci.openshift.org

[[ -z ${VAULT_TOKEN:-} ]] && echo '$VAULT_TOKEN is undefined' && exit 1

RAW_VAULT_OIDC_VALUES="$(kubectl --context=app.ci get secret -n dex vault-secret -o json)"
VAULT_OIDC_CLIENT_ID="$(echo $RAW_VAULT_OIDC_VALUES|jq '.data["vault-id"]' -r|base64 -d)"
VAULT_OIDC_CLIENT_SECRET="$(echo $RAW_VAULT_OIDC_VALUES|jq '.data["vault-secret"]' -r|base64 -d)"


# Enable kv backend
vault secrets list|grep -q kv || vault secrets enable -version=2 kv

# Enable and configure OIDC auth
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
  oidc_scopes="profile" \
  user_claim="preferred_username"

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
# Allow everyone to have a personal space for themselves in the KV store
path "secret/personal/data/{{identity.entity.aliases.${OIDC_ACCESSOR_ID}.name}}/*" {
  capabilities = ["create", "update", "read", "delete"]
}

path "secret/personal/metadata/{{identity.entity.aliases.${OIDC_ACCESSOR_ID}.name}}/*" {
  capabilities = ["list"]
}
EOH

# Make dptp members admins
echo "Setting up admin policy"
vault policy write admin -<<EOF
path "*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
EOF

# Vault auth plugins are an abstration above the real identity and create an alias. Getting from
# that alias back to the identity id which is the thing we need to set up a group is non-trivial.
echo "Finding ids for dptp members"
dptp_member_aliases='[
  "skuznets",
  "aaleman",
  "hongkliu",
  "bbarcaro",
  "apavel",
  "nmoraiti",
  "pmuller"
 ]'
dptp_ids="$(curl -Ss --fail -H "X-vault-token: ${VAULT_TOKEN}" "$VAULT_ADDR/v1/identity/entity/id?list=true" \
            |jq \
                --argjson dptp_members "$dptp_member_aliases" \
                '[.data.key_info|to_entries[]|select([.value.aliases[0].name] | inside($dptp_members))|.key]|@csv' -rc \
            |tr -d '"')"

echo "Setting up group for dptp"
vault write identity/group name="dptp" policies="admin" member_entity_ids="$dptp_ids"
