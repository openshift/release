#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export OPERATOR_SDK_VERSION="${OPERATOR_SDK_VERSION:-v1.29.0}"
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
echo "OO_INSTALL_NAMESPACE: $OO_INSTALL_NAMESPACE"
echo "OO_INSTALL_MODE:      $OO_INSTALL_MODE"

if [[ -f "${SHARED_DIR}/operator-install-namespace.txt" ]]; then
    OO_INSTALL_NAMESPACE=$(cat "$SHARED_DIR"/operator-install-namespace.txt)
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

INSTALL_MODE_ARG=""
if [[ -n ${OO_INSTALL_MODE} ]]; then
  INSTALL_MODE_ARG=--install-mode="${INSTALL_MODE_ARG}"
fi
(
  cd /tmp
  operator-sdk run bundle "${OO_BUNDLE}" -n "${OO_INSTALL_NAMESPACE}" --verbose ${INSTALL_MODE_ARG} --timeout="${OO_INSTALL_TIMEOUT_MINUTES}m"
)
