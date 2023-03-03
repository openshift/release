#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ ovn external gateways e2e commands ************"

# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# When testing PRs, this folder is populated with PR's changes
OVNK_SRC_DIR="/go/src/github.com/openshift/ovn-kubernetes"

# During periodic jobs, this folder doesn't exist and will be cloned later
if [ -d "${OVNK_SRC_DIR}" ]; then
  echo "### Copying ovnk directory"
  scp "${SSHOPTS[@]}" -r "${OVNK_SRC_DIR}" "root@${IP}:/root/dev-scripts/ovn-kubernetes"
fi


echo "### Creating script"
cat <<'EOF' >>/tmp/ovnk-ex-gw-e2e.sh
#!/usr/bin/bash

source common.sh
source network.sh
source ocp_install_env.sh

cp ${KUBECONFIG} ${HOME}/ovn.conf

version=`openshift_version`
unsupported_versions=("4.6", "4.7", "4.8" "4.9" "4.10" "4.11") # ipv4-metal-ipi was added since 4.8, exgw e2e support 4.12+

if [[ "${unsupported_versions[*]}" =~ ${version} ]]; then
    # Make collecting artifact trap not raising errors
	mkdir -p ./ovn-kubernetes/test/_artifacts/ovnk-ex-gw-e2e_not_run
    
	echo "version ${version} not supported for external gateway e2e"
    exit 0
fi


[[ -d /usr/local/go ]] && export PATH=${PATH}:/usr/local/go/bin

if [ ! -d "./ovn-kubernetes" ]; then 
	echo "### Cloning OVN-k ${version}}"
	git clone --branch release-${version} https://github.com/openshift/ovn-kubernetes.git ./ovn-kubernetes
fi


cd ovn-kubernetes/test

# nc tcp listener port
sudo firewall-cmd --zone=libvirt --permanent --add-port=91/tcp
sudo firewall-cmd --zone=libvirt --add-port=91/tcp
# nc udp listener port
sudo firewall-cmd --zone=libvirt --permanent --add-port=90/udp
sudo firewall-cmd --zone=libvirt --add-port=90/udp
# BFD control packets
sudo firewall-cmd --zone=libvirt --permanent --add-port=3784/udp
sudo firewall-cmd --zone=libvirt --add-port=3784/udp
# BFD echo packets
sudo firewall-cmd --zone=libvirt --permanent --add-port=3785/udp
sudo firewall-cmd --zone=libvirt --add-port=3785/udp
# BFD multihop packets
sudo firewall-cmd --zone=libvirt --permanent --add-port=4784/udp
sudo firewall-cmd --zone=libvirt --add-port=4784/udp

if [ "${IP_STACK}" = "v4" ]; then
	export OVN_TEST_EX_GW_IPV4=${PROVISIONING_HOST_EXTERNAL_IP}
	export OVN_TEST_EX_GW_IPV6=1111:1:1::1
elif [ "${IP_STACK}" = "v6" ]; then
	export OVN_TEST_EX_GW_IPV4=1.1.1.1
	export OVN_TEST_EX_GW_IPV6=${PROVISIONING_HOST_EXTERNAL_IP}
elif [ "${IP_STACK}" = "v4v6" ]; then
	export OVN_TEST_EX_GW_IPV4=${PROVISIONING_HOST_EXTERNAL_IP}
	export OVN_TEST_EX_GW_IPV6=1111:1:1::1
fi

# There are specifics added to openshift's kubernetes e2e framework
# that we need in order to run the e2e tests on an OpenShift cluster,
# e.g the downstream framework creates test namespaces with the
# "security.openshift.io/scc.podSecurityLabelSync"="false" label,
# which without it our test pods fail to create.
# We edit the go.mod to consume the openshift fork before running the tests,
# which in turn run go mod download.
# Also see https://github.com/openshift/kubernetes/commit/1536b7d2010d28ace898cdfeb0445b0d383de99e

cd e2e
go mod edit -replace=k8s.io/kubernetes=github.com/openshift/kubernetes@v1.24.1-0.20220920132840-8c7c96729e60 # release-4.12
go mod edit -replace=github.com/onsi/ginkgo=github.com/openshift/onsi-ginkgo@v1.14.0
go mod tidy
cd ..

export PATH=${PATH}:${HOME}/.local/bin
export CONTAINER_RUNTIME=podman
export OVN_TEST_EX_GW_NETWORK=host
make control-plane WHAT="External Gateway"
EOF

chmod +x /tmp/ovnk-ex-gw-e2e.sh

echo "### Copying E2E script to dev-scripts"
scp "${SSHOPTS[@]}" -r "/tmp/ovnk-ex-gw-e2e.sh" "root@${IP}:/root/dev-scripts/"

function collect_artifacts {
  	echo "### Collecting report artifacts"
	mkdir -p "${ARTIFACT_DIR}/"
	scp -r "${SSHOPTS[@]}" "root@${IP}:/root/dev-scripts/ovn-kubernetes/test/_artifacts/*" "${ARTIFACT_DIR}"
}
trap collect_artifacts EXIT

echo "### Running external gateways E2E on remote host"
ssh "${SSHOPTS[@]}" "root@${IP}" "cd /root/dev-scripts/ && ./ovnk-ex-gw-e2e.sh"
