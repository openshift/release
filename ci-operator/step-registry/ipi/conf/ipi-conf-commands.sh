#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cluster_name=${NAMESPACE}-${UNIQUE_HASH}

out=${SHARED_DIR}/install-config.yaml

if [[ -z "$RELEASE_IMAGE_LATEST" ]]; then
  echo "RELEASE_IMAGE_LATEST is an empty string, exiting"
  exit 1
fi

echo "Installing from release ${RELEASE_IMAGE_LATEST}"

ssh_pub_key=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
pull_secret=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")

cat > "${out}" << EOF
apiVersion: v1
metadata:
  name: ${cluster_name}
pullSecret: >
  ${pull_secret}
sshKey: |
  ${ssh_pub_key}
EOF

if [ ${FIPS_ENABLED} = "true" ]; then
	echo "Adding 'fips: true' to install-config.yaml"
	cat >> "${out}" << EOF
fips: true
EOF
fi

if [[ -n "${OS_IMAGE_STREAM}" ]]; then
    echo "Adding 'osImageStream: ${OS_IMAGE_STREAM}' to install-config.yaml"
    cat >> "${out}" << EOF
osImageStream: ${OS_IMAGE_STREAM}
EOF
fi

if [ -n "${BASELINE_CAPABILITY_SET}" ]; then
	echo "Adding 'capabilities: ...' to install-config.yaml"
	cat >> "${out}" << EOF
capabilities:
  baselineCapabilitySet: ${BASELINE_CAPABILITY_SET}
EOF
        if [ -n "${ADDITIONAL_ENABLED_CAPABILITIES}" ]; then
            cat >> "${out}" << EOF
  additionalEnabledCapabilities:
EOF
            for item in ${ADDITIONAL_ENABLED_CAPABILITIES}; do
                cat >> "${out}" << EOF
    - ${item}
EOF
            done
        fi
fi

if [ -n "${PUBLISH}" ]; then
        echo "Adding 'publish: ...' to install-config.yaml"
        cat >> "${out}" << EOF
publish: ${PUBLISH}
EOF
fi

if [ -n "${FEATURE_SET}" ]; then
        echo "Adding 'featureSet: ...' to install-config.yaml"
        cat >> "${out}" << EOF
featureSet: ${FEATURE_SET}
EOF
fi

# FeatureGates must be a valid yaml list.
# E.g. ['Feature1=true', 'Feature2=false']
# Only supported in 4.14+.
if [ -n "${FEATURE_GATES}" ]; then
        echo "Adding 'featureGates: ...' to install-config.yaml"
        cat >> "${out}" << EOF
featureGates: ${FEATURE_GATES}
EOF
fi

# tlsProfileType selects the cluster-wide TLS security profile that the
# installer renders into the APIServer config manifest. Only the values the
# installer documents are accepted so a typo fails here, before installation.
if [ -n "${INSTALL_CONFIG_TLS_PROFILE_TYPE}" ]; then
        case "${INSTALL_CONFIG_TLS_PROFILE_TYPE}" in
        Modern|Intermediate|Old) ;;
        *)
                echo "ERROR: INSTALL_CONFIG_TLS_PROFILE_TYPE must be Modern, Intermediate or Old, got '${INSTALL_CONFIG_TLS_PROFILE_TYPE}'"
                exit 1
                ;;
        esac
        echo "Adding 'tlsProfileType: ${INSTALL_CONFIG_TLS_PROFILE_TYPE}' to install-config.yaml"
        cat >> "${out}" << EOF
tlsProfileType: ${INSTALL_CONFIG_TLS_PROFILE_TYPE}
EOF
fi
