#!/usr/bin/env bash

set -Eeuo pipefail

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
export PATH=/usr/libexec/origin:$PATH

declare TEST_ARGS=''

# Force the IPv6 endpoint
if [[ "${CONFIG_TYPE}" == *"singlestackv6"* ]]; then
	export OS_CLOUD="${OS_CLOUD}-ipv6"
fi

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

# Set up the test provider for OpenStack
if test -n "${HTTP_PROXY:-}" -o -n "${HTTPS_PROXY:-}"; then
	export TEST_PROVIDER='{"type":"openstack","disconnected":true}'
else
	export TEST_PROVIDER='{"type":"openstack"}'
fi

# In order for openshift-tests to pull external binary images from the
# payload, we need access enabled to the images on the build farm. In
# order to do that, we need to unset the KUBECONFIG so we talk to the
# build farm, not the cluster under test.
echo "Granting access for image pulling from the build farm..."
KUBECONFIG_BAK=$KUBECONFIG
unset KUBECONFIG
oc adm policy add-role-to-group system:image-puller system:unauthenticated --namespace "${NAMESPACE}" || echo "Warning: Failed to grant image puller access, continuing..."
export KUBECONFIG=$KUBECONFIG_BAK

# Advertise the openstack-test OTE extension as a non-payload extension.
# openstack-test is not in the OCP release payload, so openshift-tests
# discovers it via annotated ImageStreamTags on the cluster under test
# combined with a TestExtensionAdmission CR that permits the ImageStream.
EXT_NS="openstack-test-ext"
echo "Setting up non-payload extension discovery for openstack-test..."
oc create namespace "${EXT_NS}" || true
oc import-image openstack-test:latest --from="${OPENSTACK_TEST_IMAGE}" --confirm -n "${EXT_NS}"
oc annotate istag openstack-test:latest -n "${EXT_NS}" \
	testextension.redhat.io/component=openstack-test \
	testextension.redhat.io/binary=/usr/bin/openstack-test-tests-ext.gz
cat <<EOF | oc apply -f -
apiVersion: testextension.redhat.io/v1
kind: TestExtensionAdmission
metadata:
  name: openstack-test
spec:
  permit:
  - "${EXT_NS}/openstack-test"
EOF
echo "Non-payload extension setup complete."

TEST_SUITE="openstack-test/all"

if [[ -n "${OPENSTACK_TEST_SKIPS}" ]]; then
	TESTS="$(openshift-tests run --dry-run --provider "${TEST_PROVIDER}" "${TEST_SUITE}")"
	echo "${TESTS}" | grep -v "${OPENSTACK_TEST_SKIPS}" >/tmp/tests
	echo "Skipping tests:"
	echo "${TESTS}" | grep "${OPENSTACK_TEST_SKIPS}" || { exit_code=$?; echo 'Error: no tests were found matching the OPENSTACK_TEST_SKIPS regex:'; echo "$OPENSTACK_TEST_SKIPS"; exit $exit_code; }
	TEST_ARGS="${TEST_ARGS:-} --file /tmp/tests"
fi

openshift-tests run "${TEST_SUITE}" ${TEST_ARGS:-} \
	--provider "${TEST_PROVIDER}" \
	--junit-dir "${ARTIFACT_DIR}/junit" \
	-o "${ARTIFACT_DIR}/e2e.log"
