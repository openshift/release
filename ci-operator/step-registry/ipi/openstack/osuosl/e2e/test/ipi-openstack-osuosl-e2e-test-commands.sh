#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export HOME=/tmp/home
export PATH=/usr/libexec/origin:$PATH

if [[ -n "${TEST_CSI_DRIVER_MANIFEST}" ]]; then
    export TEST_CSI_DRIVER_FILES=${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
fi

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

mkdir -p "${HOME}"

# Override the upstream docker.io registry due to issues with rate limiting
# https://bugzilla.redhat.com/show_bug.cgi?id=1895107
# sjenning: TODO: use of personal repo is temporary; should find long term location for these mirrored images
export KUBE_TEST_REPO_LIST=${HOME}/repo_list.yaml
cat << EOREGISTRY > ${KUBE_TEST_REPO_LIST}
dockerGluster: quay.io/sjenning
dockerLibraryRegistry: quay.io/sjenning
e2eRegistry: quay.io/multiarch-k8s-e2e
e2eVolumeRegistry: quay.io/multiarch-k8s-e2e
quayIncubator: quay.io/multiarch-k8s-e2e
quayK8sCSI: quay.io/multiarch-k8s-e2e
k8sCSI: quay.io/multiarch-k8s-e2e
promoterE2eRegistry: quay.io/multiarch-k8s-e2e
sigStorageRegistry: quay.io/multiarch-k8s-e2e
EOREGISTRY

# if the cluster profile included an insights secret, install it to the cluster to
# report support data from the support-operator
if [[ -f "${CLUSTER_PROFILE_DIR}/insights-live.yaml" ]]; then
    oc create -f "${CLUSTER_PROFILE_DIR}/insights-live.yaml" || true
fi

export TEST_PROVIDER='{"type":"openstack"}'

mkdir -p /tmp/output
cd /tmp/output

function upgrade() {
    set -x
    openshift-tests run-upgrade all \
        --to-image "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}" \
        --options "${TEST_UPGRADE_OPTIONS-}" \
        --provider "${TEST_PROVIDER}" \
        -o "${ARTIFACT_DIR}/e2e.log" \
        --junit-dir "${ARTIFACT_DIR}/junit"
    set +x
}

function suite() {
    if [[ -n "${TEST_SKIPS}" ]]; then

        TESTS="$(openshift-tests run --dry-run --provider "${TEST_PROVIDER}" "${TEST_SUITE}")"
        echo "${TESTS}" | grep -v "${TEST_SKIPS}" >/tmp/tests
        echo "Skipping tests:"
        echo "${TESTS}" | grep "${TEST_SKIPS}"
        TEST_ARGS="${TEST_ARGS:-} --file /tmp/tests"

    else

        cat > /tmp/invert_excluded.py <<EOSCRIPT
#!/usr/libexec/platform-python
import sys
all_tests = set()
excluded_tests = set()
for l in sys.stdin.readlines():
  all_tests.add(l.strip())
with open(sys.argv[1], "r") as f:
  for l in f.readlines():
    excluded_tests.add(l.strip())
test_suite = all_tests - excluded_tests
for t in test_suite:
  print(t)
EOSCRIPT
        chmod +x /tmp/invert_excluded.py
        cat > /tmp/excluded_tests <<EOEXCLUDE
"[sig-auth][Feature:LDAP] LDAP IDP should authenticate against an ldap server [Suite:openshift/conformance/parallel]"
"[sig-auth][Feature:HTPasswdAuth] HTPasswd IDP should successfully configure htpasswd and be responsive [Suite:openshift/conformance/parallel]"
"[sig-auth][Feature:OAuthServer] [Headers] expected headers returned from the authorize URL [Suite:openshift/conformance/parallel]"
"[sig-auth][Feature:OAuthServer] [Headers] expected headers returned from the grant URL [Suite:openshift/conformance/parallel]"
"[sig-auth][Feature:OAuthServer] [Headers] expected headers returned from the login URL for the allow all IDP [Suite:openshift/conformance/parallel]"
"[sig-auth][Feature:OAuthServer] [Headers] expected headers returned from the login URL for the bootstrap IDP [Suite:openshift/conformance/parallel]"
"[sig-auth][Feature:OAuthServer] [Headers] expected headers returned from the login URL for when there is only one IDP [Suite:openshift/conformance/parallel]"
"[sig-auth][Feature:OAuthServer] [Headers] expected headers returned from the logout URL [Suite:openshift/conformance/parallel]"
"[sig-auth][Feature:OAuthServer] [Headers] expected headers returned from the root URL [Suite:openshift/conformance/parallel]"
"[sig-auth][Feature:OAuthServer] [Headers] expected headers returned from the token URL [Suite:openshift/conformance/parallel]"
"[sig-auth][Feature:OAuthServer] [Headers] expected headers returned from the token request URL [Suite:openshift/conformance/parallel]"
"[sig-auth][Feature:OAuthServer] [Token Expiration] Using a OAuth client with a non-default token max age to generate tokens that do not expire works as expected when using a code authorization flow [Suite:openshift/conformance/parallel]"
"[sig-auth][Feature:OAuthServer] [Token Expiration] Using a OAuth client with a non-default token max age to generate tokens that do not expire works as expected when using a token authorization flow [Suite:openshift/conformance/parallel]"
"[sig-auth][Feature:OAuthServer] [Token Expiration] Using a OAuth client with a non-default token max age to generate tokens that expire shortly works as expected when using a code authorization flow [Suite:openshift/conformance/parallel]"
"[sig-auth][Feature:OAuthServer] [Token Expiration] Using a OAuth client with a non-default token max age to generate tokens that expire shortly works as expected when using a token authorization flow [Suite:openshift/conformance/parallel]"
"[sig-builds][Feature:Builds] build have source revision metadata  started build should contain source revision information [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-builds][Feature:Builds] build with empty source  started build should build even with an empty source in build config [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-builds][Feature:Builds] build without output image  building from templates should create an image from a S2i template without an output image reference defined [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-builds][Feature:Builds] result image should have proper labels set  S2I build from a template should create a image from \"test-s2i-build.json\" template with proper Docker labels [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-builds][Feature:Builds] s2i build with a quota  Building from a template should create an s2i build with a quota and run it [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-builds][Feature:Builds] s2i build with a root user image should create a root build and pass with a privileged SCC [Suite:openshift/conformance/parallel]"
"[sig-builds][Feature:Builds][timing] capture build stages and durations  should record build stages and durations for s2i [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-builds][Feature:Builds][valueFrom] process valueFrom in build strategy environment variables  should successfully resolve valueFrom in s2i build environment variables [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-devex][Feature:Templates] templateinstance readiness test  should report ready soon after all annotated objects are ready [Suite:openshift/conformance/parallel]"
"[sig-instrumentation] Prometheus when installed on the cluster shouldn't report any alerts in firing state apart from Watchdog and AlertmanagerReceiversNotConfigured [Early] [Suite:openshift/conformance/parallel]"
"[sig-network-edge][Conformance][Area:Networking][Feature:Router] The HAProxy router should be able to connect to a service that is idled because a GET on the route will unidle it [Suite:openshift/conformance/parallel/minimal]"
"[sig-network] NetworkPolicy [LinuxOnly] NetworkPolicy between server and client should allow egress access on one named port [Feature:NetworkPolicy] [Skipped:Network/OVNKubernetes] [Skipped:Network/OpenShiftSDN/Multitenant] [Skipped:Network/OpenShiftSDN] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] NetworkPolicy [LinuxOnly] NetworkPolicy between server and client should allow egress access to server in CIDR block [Feature:NetworkPolicy] [Skipped:Network/OpenShiftSDN/Multitenant] [Skipped:Network/OpenShiftSDN] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] NetworkPolicy [LinuxOnly] NetworkPolicy between server and client should allow ingress access from namespace on one named port [Feature:NetworkPolicy] [Skipped:Network/OVNKubernetes] [Skipped:Network/OpenShiftSDN/Multitenant] [Skipped:Network/OpenShiftSDN] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] NetworkPolicy [LinuxOnly] NetworkPolicy between server and client should allow ingress access on one named port [Feature:NetworkPolicy] [Skipped:Network/OVNKubernetes] [Skipped:Network/OpenShiftSDN/Multitenant] [Skipped:Network/OpenShiftSDN] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] NetworkPolicy [LinuxOnly] NetworkPolicy between server and client should enforce egress policy allowing traffic to a server in a different namespace based on PodSelector and NamespaceSelector [Feature:NetworkPolicy] [Skipped:Network/OpenShiftSDN/Multitenant] [Skipped:Network/OpenShiftSDN] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] NetworkPolicy [LinuxOnly] NetworkPolicy between server and client should enforce except clause while egress access to server in CIDR block [Feature:NetworkPolicy] [Skipped:Network/OpenShiftSDN/Multitenant] [Skipped:Network/OpenShiftSDN] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] NetworkPolicy [LinuxOnly] NetworkPolicy between server and client should enforce multiple egress policies with egress allow-all policy taking precedence [Feature:NetworkPolicy] [Skipped:Network/OpenShiftSDN/Multitenant] [Skipped:Network/OpenShiftSDN] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] NetworkPolicy [LinuxOnly] NetworkPolicy between server and client should enforce multiple ingress policies with ingress allow-all policy taking precedence [Feature:NetworkPolicy] [Skipped:Network/OpenShiftSDN/Multitenant] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] NetworkPolicy [LinuxOnly] NetworkPolicy between server and client should enforce multiple, stacked policies with overlapping podSelectors [Feature:NetworkPolicy] [Skipped:Network/OpenShiftSDN/Multitenant] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] NetworkPolicy [LinuxOnly] NetworkPolicy between server and client should enforce policy based on PodSelector with MatchExpressions[Feature:NetworkPolicy] [Skipped:Network/OpenShiftSDN/Multitenant] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] NetworkPolicy [LinuxOnly] NetworkPolicy between server and client should enforce policy to allow traffic only from a pod in a different namespace based on PodSelector and NamespaceSelector [Feature:NetworkPolicy] [Skipped:Network/OpenShiftSDN/Multitenant] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] NetworkPolicy [LinuxOnly] NetworkPolicy between server and client should ensure an IP overlapping both IPBlock.CIDR and IPBlock.Except is allowed [Feature:NetworkPolicy] [Skipped:Network/OpenShiftSDN/Multitenant] [Skipped:Network/OpenShiftSDN] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] NetworkPolicy [LinuxOnly] NetworkPolicy between server and client should support a 'default-deny-all' policy [Feature:NetworkPolicy] [Skipped:Network/OpenShiftSDN/Multitenant] [Skipped:Network/OpenShiftSDN] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] NetworkPolicy [LinuxOnly] NetworkPolicy between server and client should work with Ingress,Egress specified together [Feature:NetworkPolicy] [Skipped:Network/OpenShiftSDN/Multitenant] [Skipped:Network/OpenShiftSDN] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] CSI mock volume CSI FSGroupPolicy [LinuxOnly] should not modify fsGroup if fsGroupPolicy=None [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] Secrets optional updates should be reflected in volume [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
EOEXCLUDE

	# @TODO investigate testcases after this point"
        cat >> /tmp/excluded_tests <<EOEXCLUDE
"[sig-builds][Feature:Builds] Multi-stage image builds should succeed [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-builds][Feature:Builds] prune builds based on settings in the buildconfig  should prune completed builds based on the successfulBuildsHistoryLimit setting [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-network] Networking IPerf2 [Feature:Networking-Performance] should run iperf2 [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Services should have session affinity timeout work for NodePort service [LinuxOnly] [Conformance] [Skipped:Network/OVNKubernetes] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-node] Probing container should be ready immediately after startupProbe succeeds [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-node] Probing container should override timeoutGracePeriodSeconds when LivenessProbe field is set [Feature:ProbeTerminationGracePeriod] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-node] should override timeoutGracePeriodSeconds when annotation is set [Suite:openshift/conformance/parallel]"
"[sig-storage] In-tree Volumes [Driver: cinder] [Testpattern: Inline-volume (default fs)] volumes should allow exec of files on the volume [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: cinder] [Testpattern: Inline-volume (default fs)] volumes should store data [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: cinder] [Testpattern: Pre-provisioned PV (block volmode)] volumeMode should not mount / map unused volumes in a pod [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: cinder] [Testpattern: Pre-provisioned PV (block volmode)] volumes should store data [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: cinder] [Testpattern: Pre-provisioned PV (default fs)] volumes should allow exec of files on the volume [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: cinder] [Testpattern: Pre-provisioned PV (default fs)] volumes should store data [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] In-tree Volumes [Driver: cinder] [Testpattern: Pre-provisioned PV (filesystem volmode)] volumeMode should not mount / map unused volumes in a pod [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
EOEXCLUDE

        openshift-tests run openshift/conformance/parallel --dry-run | /tmp/invert_excluded.py /tmp/excluded_tests > /tmp/tests

        TEST_ARGS="${TEST_ARGS:-} --file /tmp/tests"
    fi

    VERBOSITY="" # "--v 9"
    openshift-tests run --from-repository quay.io/multi-arch/community-e2e-images \
	${VERBOSITY} \
	"${TEST_SUITE}" \
	${TEST_ARGS:-} \
        --provider "${TEST_PROVIDER}" \
        -o "${ARTIFACT_DIR}/e2e.log" \
        --junit-dir "${ARTIFACT_DIR}/junit"
}

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_START"
trap 'echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_END"' EXIT

case "${TEST_TYPE}" in
upgrade-conformance)
    upgrade
    TEST_LIMIT_START_TIME="$(date +%s)" TEST_SUITE=openshift/conformance/parallel suite
    ;;
upgrade)
    upgrade
    ;;
suite-conformance)
    suite
    TEST_LIMIT_START_TIME="$(date +%s)" TEST_SUITE=openshift/conformance/parallel suite
    ;;
suite)
    suite
    ;;
*)
    echo >&2 "Unsupported test type '${TEST_TYPE}'"
    exit 1
    ;;
esac
