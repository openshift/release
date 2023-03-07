#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export OPERATOR_SDK_VERSION="${OPERATOR_SDK_VERSION:-v1.27.0}"
# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "== Parameters:"
echo "OO_BUNDLE:            $OO_BUNDLE"
#echo "OO_PACKAGE:           $OO_PACKAGE"
#echo "OO_CHANNEL:           $OO_CHANNEL"
echo "OO_INSTALL_NAMESPACE: $OO_INSTALL_NAMESPACE"
echo "OO_TARGET_NAMESPACES: $OO_TARGET_NAMESPACES"
#echo "TEST_MODE: $TEST_MODE"

if [[ -f "${SHARED_DIR}/operator-install-namespace.txt" ]]; then
    OO_INSTALL_NAMESPACE=$(cat "$SHARED_DIR"/operator-install-namespace.txt)
elif [[ "$OO_INSTALL_NAMESPACE" == "!create" ]]; then
    echo "OO_INSTALL_NAMESPACE is '!create': creating new namespace"
    NS_NAMESTANZA="generateName: oo-"
elif ! oc get namespace "$OO_INSTALL_NAMESPACE"; then
    echo "OO_INSTALL_NAMESPACE is '$OO_INSTALL_NAMESPACE' which does not exist: creating"
    NS_NAMESTANZA="name: $OO_INSTALL_NAMESPACE"
else
    echo "OO_INSTALL_NAMESPACE is '$OO_INSTALL_NAMESPACE'"
fi

if [[ -n "${NS_NAMESTANZA:-}" ]]; then
    OO_INSTALL_NAMESPACE=$(
        oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: v1
kind: Namespace
metadata:
  $NS_NAMESTANZA
EOF
    )
fi

if [[ "${OO_INSTALL_NAMESPACE}" =~ ^openshift- ]]; then
    echo "Setting label security.openshift.io/scc.podSecurityLabelSync value to true on the namespace \"$OO_INSTALL_NAMESPACE\""
    oc label --overwrite ns "${OO_INSTALL_NAMESPACE}" security.openshift.io/scc.podSecurityLabelSync=true
fi

if [[ "$OO_TARGET_NAMESPACES" == "!install" ]]; then
    echo "OO_TARGET_NAMESPACES is '!install': targeting operator installation namespace ($OO_INSTALL_NAMESPACE)"
    OO_TARGET_NAMESPACES="$OO_INSTALL_NAMESPACE"
elif [[ "$OO_TARGET_NAMESPACES" == "!all" ]]; then
    echo "OO_TARGET_NAMESPACES is '!all': all namespaces will be targeted"
    OO_TARGET_NAMESPACES=""
fi

TARGET_NAMESPACES_ARG=""
if [[ -n ${OO_TARGET_NAMESPACES} ]]; then
  TARGET_NAMESPACES_ARG="--install-mode=${OO_TARGET_NAMESPACES}"
fi
export TARGET_NAMESPACES_ARG

echo "Downloading the operator-sdk"
ARCH=$(case $(uname -m) in x86_64) echo -n amd64 ;; aarch64) echo -n arm64 ;; *) echo -n "$(uname -m)" ;; esac)
export ARCH
OS=$(uname | awk '{print tolower($0)}')
export OS

(
cd "${SHARED_DIR}"
export OPERATOR_SDK_DL_URL="https://github.com/operator-framework/operator-sdk/releases/download/${OPERATOR_SDK_VERSION}"
curl -L "${OPERATOR_SDK_DL_URL}/operator-sdk_${OS}_${ARCH}" -o operator-sdk
chmod +x operator-sdk

./operator-sdk run bundle "${OO_BUNDLE}" -n "${OO_INSTALL_NAMESPACE}" --verbose ${TARGET_NAMESPACES_ARG}
)