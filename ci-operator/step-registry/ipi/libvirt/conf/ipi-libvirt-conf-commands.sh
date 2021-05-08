#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ e2e conf command ************"

# List of include cases

read -d '#' INCL << EOF
[sig-storage] In-tree Volumes [Driver: azure-disk] [Testpattern: Pre-provisioned PV (ntfs)][sig-windows] volumes should store data [Suite:openshift/conformance/parallel] [Suite:k8s]
[sig-storage] CSI mock volume CSI workload information using mock driver should not be passed when podInfoOnMount=false [Suite:openshift/conformance/parallel] [Suite:k8s]
[sig-storage] In-tree Volumes [Driver: hostPathSymlink] [Testpattern: Dynamic PV (default fs)] volumes should allow exec of files on the volume [Suite:openshift/conformance/parallel] [Suite:k8s]
[sig-storage] In-tree Volumes [Driver: vsphere] [Testpattern: Dynamic PV (delayed binding)] topology should provision a volume and schedule a pod with AllowedTopologies [Suite:openshift/conformance/parallel] [Suite:k8s]
[sig-auth][Feature:OpenShiftAuthorization] RBAC proxy for openshift authz  RunLegacyClusterRoleBindingEndpoint should succeed [Suite:openshift/conformance/parallel]
[sig-storage] CSI Volumes [Driver: csi-hostpath] [Testpattern: Generic Ephemeral-volume (default fs) [Feature:GenericEphemeralVolume] (immediate-binding)] ephemeral should support multiple inline ephemeral volumes [Suite:openshift/conformance/parallel] [Suite:k8s]
[sig-builds][Feature:Builds] prune builds based on settings in the buildconfig  should prune errored builds based on the failedBuildsHistoryLimit setting [Suite:openshift/conformance/parallel]
[sig-storage] Dynamic Provisioning [k8s.io] GlusterDynamicProvisioner should create and delete persistent volumes [fast] [Suite:openshift/conformance/parallel] [Suite:k8s]
[sig-storage] GCP Volumes GlusterFS should be mountable [Suite:openshift/conformance/parallel] [Suite:k8s]
[sig-apps][Feature:DeploymentConfig] deploymentconfigs when tagging images should successfully tag the deployed image [Suite:openshift/conformance/parallel]
[sig-arch] Managed cluster should have no crashlooping pods in core namespaces over four minutes [Suite:openshift/conformance/parallel]
[sig-auth][Feature:HTPasswdAuth] HTPasswd IDP should successfully configure htpasswd and be responsive [Suite:openshift/conformance/parallel]
[sig-auth][Feature:LDAP] LDAP IDP should authenticate against an ldap server [Suite:openshift/conformance/parallel]
[sig-auth][Feature:LDAP] LDAP should start an OpenLDAP test server [Suite:openshift/conformance/parallel]
[sig-auth][Feature:OAuthServer] [Headers] expected headers returned from the authorize URL [Suite:openshift/conformance/parallel]
[sig-auth][Feature:OAuthServer] [Headers] expected headers returned from the grant URL [Suite:openshift/conformance/parallel]

#
EOF

cat <(echo "$INCL") > "${SHARED_DIR}/test-list"