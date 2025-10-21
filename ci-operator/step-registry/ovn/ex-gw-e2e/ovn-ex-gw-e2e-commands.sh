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
unsupported_versions=("4.8" "4.9" "4.10" "4.11") # ipv4-metal-ipi was added since 4.8, exgw e2e support 4.12+

if [[ "${unsupported_versions[*]}" =~ ${version} ]]; then
    echo "version ${version} not supported for external gateway e2e"
    exit 0
fi


[[ -d /usr/local/go ]] && export PATH=${PATH}:/usr/local/go/bin

set -x
if [ ! -d "./ovn-kubernetes" ]; then
	echo "### Cloning OVN-k ${version}}"
	git clone --branch release-${version} https://github.com/openshift/ovn-kubernetes.git ./ovn-kubernetes
  if [ "$JOB_TYPE" == "presubmit" ] && [[ "$JOB_NAME" == pull-* ]]; then
      pushd ovn-kubernetes
      git fetch origin "pull/${PULL_NUMBER}/head"
      git checkout -b "pr-${PULL_NUMBER}" FETCH_HEAD
      popd
  fi
fi
set +x

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

pushd e2e
echo "OpenShift version: ${version}"
GINKGO_FOCUS="External Gateway"
# these are the hacks needed to get the tests to build and run for each version. There may be smarter
# ways to do this...
if [[ "${version}" == "4.12" ]]; then
    go mod edit -replace=k8s.io/kubernetes=github.com/openshift/kubernetes@v1.24.1-0.20220920132840-8c7c96729e60
    go mod edit -replace=github.com/onsi/ginkgo=github.com/openshift/onsi-ginkgo@v1.14.0
    GINKGO_FOCUS="e2e non-vxlan external gateway through a gateway pod"
elif [[ "${version}" == "4.13" ]]; then
    sed -i '/^import (/a\	"k8s.io/apimachinery/pkg/util/sets"' service.go
    go mod edit -replace=k8s.io/kubernetes=github.com/openshift/kubernetes@v1.24.1-0.20220920132840-8c7c96729e60
    go mod edit -replace=github.com/onsi/ginkgo=github.com/openshift/onsi-ginkgo@v1.14.0
    GINKGO_FOCUS="e2e non-vxlan external gateway through a gateway pod"
elif [[ "${version}" == "4.14" ]]; then
    # this is very hacky in order to find a way to get the tests to build. Essentially it's re-checking
    # out 4.14 and then updating just the test/e2e folder to be 4.15 so it can build with the additional
    # go mod edit changes. In the case that this is a presubmit job we want to try to get back any
    # changes from that PR that may exist in test/e2e. there is chance that would have a conflict, and if
    # so we just give up. This is only needed for 4.14 becuase of having to hack in 4.15 for test/e2e. All
    # other versions in this step will be checked-out with their PR from the earlier section when the
    # repo was initially checked out.
    git checkout release-4.14
    git fetch origin release-4.15:release-4.15
    git checkout release-4.15 ./
    go mod edit -replace=k8s.io/kubernetes=github.com/openshift/kubernetes@v1.28.3-0.20240206100603-f1618d54a81f
    go mod edit -replace=k8s.io/apiserver=k8s.io/apiserver@v0.0.0-20231008015037-850deeb40c83
    if [ "$JOB_TYPE" == "presubmit" ] && [[ "$JOB_NAME" == pull-* ]]; then
        go mod tidy
        go mod vendor
        git config --global user.email "devnull@openshift.org"
        git config --global user.name "OpenShift Name"
        git commit -am "test/e2e is 4.15"
        git fetch origin "pull/${PULL_NUMBER}/head:temp-pr-branch"
        if ! git cherry-pick "pr-${PULL_NUMBER}"; then
            echo "Cherry-pick had conflicts. The PR is on branch 4.14 but test/e2e has been checked out @ 4.15 which may be the reason"
            git status
            exit 1
        fi
    fi
elif (( $(echo "${version} >= 4.15" | bc -l) )); then
    # currently (Feb 2024) 4.15 and 4.16 will build and run tests with the below modifications to test/e2e/go.mod
    # but it's possible that 4.16+ could change to a point where this would need to be updated with other changes or
    # probably move to a new condition specifically for 4.16+
    go mod edit -replace=k8s.io/kubernetes=github.com/openshift/kubernetes@v1.28.3-0.20240206100603-f1618d54a81f
    go mod edit -replace=k8s.io/apiserver=k8s.io/apiserver@v0.0.0-20231008015037-850deeb40c83 # 1.28 before breaking change in UnauthenticatedHTTP2DOSMitigation gate
else
    echo "Unknown version variable: ${version}"
    exit 1
fi
go mod tidy
go mod vendor
popd

export PATH=${PATH}:${HOME}/.local/bin
export CONTAINER_RUNTIME=podman
export OVN_TEST_EX_GW_NETWORK=host
make control-plane WHAT="$GINKGO_FOCUS"
EOF

chmod +x /tmp/ovnk-ex-gw-e2e.sh

echo "### Copying E2E script to dev-scripts"
scp "${SSHOPTS[@]}" -r "/tmp/ovnk-ex-gw-e2e.sh" "root@${IP}:/root/dev-scripts/"

echo "### Running external gateways E2E on remote host"
ssh "${SSHOPTS[@]}" "root@${IP}" "cd /root/dev-scripts/ && ./ovnk-ex-gw-e2e.sh"
