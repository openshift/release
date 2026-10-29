#!/usr/bin/env bash

set -euo pipefail

echo "Checking the existence of external OIDC cache files"
if [[ ! -r "$SHARED_DIR/oc-oidc-token" ]]; then
    echo "SHARED_DIR/oc-oidc-token is either not found or not readable, exiting"
    exit 1
fi
if [[ ! -r "$SHARED_DIR/oc-oidc-token-filename" ]]; then
    echo "SHARED_DIR/oc-oidc-token-filename is either not found or not readable, exiting"
    exit 1
fi

echo "Restoring external OIDC cache dir"
mkdir -p ~/.kube/cache/oc
cat "$SHARED_DIR/oc-oidc-token" > ~/.kube/cache/oc/"$(cat "$SHARED_DIR/oc-oidc-token-filename")"

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    echo "Setting up proxy"
    source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "Getting the external user's name"
ext_user_name="$(oc whoami)"

echo "Parsing contexts within the kubeconfig"
ext_oidc_context="$(oc config current-context)"
non_ext_oidc_context="$(oc config view -o json | jq -r '.contexts[] | select(.name!="'"$ext_oidc_context"'").name')"
if [[ -z "$non_ext_oidc_context" ]]; then
    echo "No non-external-oidc context found, exiting"
    exit 1
fi
if (( $(echo "$non_ext_oidc_context" | wc -l) > 1 )); then
    echo "More than one non-external-oidc contexts found: $non_ext_oidc_context, exiting"
    exit 1
fi

echo "Switching to the $non_ext_oidc_context context"
oc config use-context "$non_ext_oidc_context"
oc whoami
CLUSTER_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
AUTH_CONFIG=$(oc get authentication.config cluster -o json | jq -c)

echo "Granting ClusterRole $EXT_OIDC_ROLE_NAME to the external user"
cat <<EOF | oc create -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ext-oidc-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: $EXT_OIDC_ROLE_NAME
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: $ext_user_name
EOF

echo "Making sure that the external user has appropriate permissions"
oc config use-context "$ext_oidc_context" 2>&1 | sed -E "s|/[^/]+/|/XXXXXXXXXXXX/|"
# Save external oidc kubeconfig for the later qe test suite using 
oc config view --flatten --raw > "$SHARED_DIR"/external-oidc-user.kubeconfig
oc whoami

# OCPBUGS-57736 has no backport to 4.19
if [[ $(awk "BEGIN {print ($CLUSTER_VERSION >= 4.20)}") == "1"  ]]; then
    if grep -qE "extratest.openshift.com/bar.*extratest.openshift.com/foo.*testuid-.+-uidtest" <<< $AUTH_CONFIG; then
        USER_INFO_JSON=$(oc auth whoami -o jsonpath='{.status.userInfo}')
        # The values in the grep patterns are configured otherwhere and tested as checkpoints here
        if jq -c '.extra' <<< "$USER_INFO_JSON" | grep -qE '"extratest.openshift.com/bar":\[".+"\],"extratest.openshift.com/foo":\[".+"\]' && jq -c '.uid' <<< "$USER_INFO_JSON" | grep -qE 'testuid-.+-uidtest'; then
            echo "External OIDC uid and extra are retrieved in userInfo as configured."
        else
            echo "The retrieved userInfo: $USER_INFO_JSON"
            echo "External OIDC uid and extra are not retrieved in userInfo as configured!"
            exit 1
        fi
    fi
fi
oc get co

echo "Switching to the $non_ext_oidc_context context"
oc config use-context "$non_ext_oidc_context"
oc whoami
echo "The KUBECONFIG is $KUBECONFIG" # This line is intentionally added for possible debugging
