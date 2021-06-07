#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ e2e conf command ************"

# List of include cases

read -d '#' INCL << EOF
[sig-auth][Feature:LDAP] LDAP IDP should authenticate against an ldap server [Suite:openshift/conformance/parallel]
[sig-auth][Feature:HTPasswdAuth] HTPasswd IDP should successfully configure htpasswd and be responsive [Suite:openshift/conformance/parallel]
[sig-auth][Feature:OAuthServer] [Headers] expected headers returned from the authorize URL [Suite:openshift/conformance/parallel]
[sig-auth][Feature:OAuthServer] [Headers] expected headers returned from the grant URL [Suite:openshift/conformance/parallel]
[sig-auth][Feature:OAuthServer] [Headers] expected headers returned from the login URL for the allow all IDP [Suite:openshift/conformance/parallel]
[sig-auth][Feature:OAuthServer] [Headers] expected headers returned from the login URL for the bootstrap IDP [Suite:openshift/conformance/parallel]
[sig-auth][Feature:OAuthServer] [Headers] expected headers returned from the login URL for when there is only one IDP [Suite:openshift/conformance/parallel]
[sig-auth][Feature:OAuthServer] [Headers] expected headers returned from the logout URL [Suite:openshift/conformance/parallel]
[sig-auth][Feature:OAuthServer] [Headers] expected headers returned from the root URL [Suite:openshift/conformance/parallel]
[sig-auth][Feature:OAuthServer] [Headers] expected headers returned from the token URL [Suite:openshift/conformance/parallel]
[sig-auth][Feature:OAuthServer] [Headers] expected headers returned from the token request URL [Suite:openshift/conformance/parallel]
[sig-auth][Feature:OAuthServer] [Token Expiration] Using a OAuth client with a non-default token max age to generate tokens that do not expire works as expected when using a code authorization flow [Suite:openshift/conformance/parallel]
[sig-auth][Feature:OAuthServer] [Token Expiration] Using a OAuth client with a non-default token max age to generate tokens that do not expire works as expected when using a token authorization flow [Suite:openshift/conformance/parallel]
[sig-auth][Feature:OAuthServer] [Token Expiration] Using a OAuth client with a non-default token max age to generate tokens that expire shortly works as expected when using a code authorization flow [Suite:openshift/conformance/parallel]
[sig-auth][Feature:OAuthServer] [Token Expiration] Using a OAuth client with a non-default token max age to generate tokens that expire shortly works as expected when using a token authorization flow [Suite:openshift/conformance/parallel]
[sig-devex][Feature:Templates] templateinstance readiness test  should report ready soon after all annotated objects are ready [Suite:openshift/conformance/parallel]
[sig-storage] CSI mock volume CSI FSGroupPolicy [LinuxOnly] should not modify fsGroup if fsGroupPolicy=None [Suite:openshift/conformance/parallel] [Suite:k8s]
[sig-storage] Secrets optional updates should be reflected in volume [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]
#
EOF

cat <(echo "$INCL") > "${SHARED_DIR}/excluded_tests"
