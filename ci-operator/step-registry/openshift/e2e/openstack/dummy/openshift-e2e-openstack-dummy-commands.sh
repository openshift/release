#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function info() {
  printf '%s: INFO: %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
# if test -f "${SHARED_DIR}/proxy-conf.sh"
# then
#	# shellcheck disable=SC1090
#	source "${SHARED_DIR}/proxy-conf.sh"
# fi

export SECRECTS="/var/run/cluster-secrets/rhoso-giant28"
export KUBECONFIG=${SECRECTS}/underlying-kubeconfig
export OSPCERT=${SECRECTS}/osp-ca.crt
export OS_CLIENT_CONFIG_FILE=${SECRECTS}/clouds.yaml
export OS_CLOUD=openstack

if [[ ! -f "${KUBECONFIG}" ]]; then
	info "underlying-kubeconfig wasn't found"
    exit 1
fi

# Test curl agains giant28 proxy
curl -vvv 10.37.137.38:3128

# Load the proxy
proxy_host=$(yq -r '.clusters[0].cluster."proxy-url"' "${KUBECONFIG}" | cut -d/ -f3 | cut -d: -f1)
info "Permanent proxy detected: $proxy_host"
export HTTP_PROXY=http://${proxy_host}:3128/
export HTTPS_PROXY=http://${proxy_host}:3128/
export NO_PROXY="redhat.io,quay.io,redhat.com,svc,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,localhost,127.0.0.1"

export http_proxy=http://${proxy_host}:3128/
export https_proxy=http://${proxy_host}:3128/
export no_proxy="redhat.io,quay.io,redhat.com,svc,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,localhost,127.0.0.1"

info "Get openstack catalog list from using the openstackclient"
openstack --os-cacert ${OSPCERT} catalog list

# Get openstack catalog list from the underlying ocp (where run the RHOSO Control Plane)
info "Get openstack catalog list from the underlying ocp"
oc rsh -n openstack openstackclient openstack catalog list