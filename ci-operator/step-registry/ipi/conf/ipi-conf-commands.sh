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
additionalTrustBundle: |
  -----BEGIN CERTIFICATE-----
  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
  bTSegOgySxp2uzPJqg==
  -----END CERTIFICATE-----
  -----BEGIN CERTIFICATE-----
  MIIFuDCCA6CgAwIBAgIJAJk39xzKHHf9MA0GCSqGSIb3DQEBCwUAMGkxCzAJBgNV
  BAYTAkNOMRAwDgYDVQQIDAdCZWlqaW5nMRAwDgYDVQQHDAdCZWlqaW5nMQwwCgYD
  VQQKDANPQ1AxDzANBgNVBAsMBk9DUC1RRTEXMBUGA1UEAwwOT0NQLVFFLVJPT1Qt
  Q0EwHhcNMTkwODE4MDYwNzU4WhcNMzkwODEzMDYwNzU4WjBpMQswCQYDVQQGEwJD
  TjEQMA4GA1UECAwHQmVpamluZzEQMA4GA1UEBwwHQmVpamluZzEMMAoGA1UECgwD
  T0NQMQ8wDQYDVQQLDAZPQ1AtUUUxFzAVBgNVBAMMDk9DUC1RRS1ST09ULUNBMIIC
  IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA338oV6IIvllZpr/lWOjMMVZq
  4Smm0qA6BOe3ezZlr2LU5TLsgZeY+Oa1YtwXSAka8rRnuuqNa6gZEHGdL1SHTynB
  rEyq05KErChLabRVYb9aotQHt1+G1GG2Mi11QZ4Pdgsfmrs8NC05703C5V4kEL+q
  NXG88O3J54ySsKp+aD4xvOtZ0uXcVdjAo347/CJEm/2HF9C/uIR8ktJ43ZQPq55c
  tgsJjjY/UBSmOOhDsTfRzv9DVrcWuZYW0ZztG7gfC3d2i2l7dLhaAr76kzZ68aH2
  402ghE1Xh9zDlmWugfqOyT/v6RsE7gL/Dkkuk27Eau3jyRdWVIJroqK2Sd/yJcrQ
  DiG1wAzwb7JVlPi5lkQBrWXti+qgm415+Xfcc9KRZP3hv3tbGVuKmNxONpGjbrMw
  GKV2EMWGnpdKepQ0STWb9SC916iNXO9ffCsPlqgEoV1ONiNfvU9G3cCcRcc1yjtF
  8zbMcqmtsvl+AC1RfmM4n8TesSx56vk/obNsUljtU1/FGQIKRlamey4r/dKDR8kJ
  oyDibv7dUGm5pX5/L7bahRb7LoVg0MbV9bGlqL+hpCbjIO1rouMyy3qu3z+NMGh7
  nzVYULulOjdbVw5u14O4VeonavWByyCFUMK4JKqfUOPNjjS7OEXue1HoCy9LBjIv
  qfPUdeulyX0OtbZ8EhECAwEAAaNjMGEwHQYDVR0OBBYEFG5nokgYqmIIwaW7blM6
  wHVIQwBIMB8GA1UdIwQYMBaAFG5nokgYqmIIwaW7blM6wHVIQwBIMA8GA1UdEwEB
  /wQFMAMBAf8wDgYDVR0PAQH/BAQDAgGGMA0GCSqGSIb3DQEBCwUAA4ICAQAcnBrb
  Cde2jE+iumzlN3TNm6nOvMnomIrMupBInuWI0GvA9rGjv8SC8ZAjfx/fZOY28uLx
  ACiZqKWQT0YARjKCgOSe0RxTG+vpNH6E8FpTEiVIq/N+rgdHCZUJiWoY7BA1FNNq
  3UTlqV6RM+RqsVIptu8lk7fVDehng+zQzYYs4ZV6bSLjBQG3yBUBN1lYnFWe3pnS
  WmLuw22Riuunc5MVdH97modji1UDzQHDbYy0FXt8gLM8DRPIrOe039XO1lO+eWWM
  /NI7sZBU6bSotDh3aTLnHIyJdJ0dnh+/wMIK6h5au/7BMV1oK4JsSmpNCmzP+s3O
  cpNINYhkBRqFViA72D/Vim/meP2Q4J/dKsT2JbprY7X/XIYd1+aS48QAyusat2Gn
  KJ1JQNOoYHGijz8bYHm5JVytMIKU5LJ/Rp9SgK3d0ByqmJR76alzyRdUKa3Pmsw3
  Beq8GQSAdjlyIB6C1FpG7XD4ySz1EjGEcOXiGiEi8l9wjDgLtA20U9ALaMcEdODY
  K8zhyirrdXdV8XHBAE7QBkzcuQAVc9iyTNoqCfJBtvl2HYpH2XoRhxP0rX9NtAYE
  Gc+Yc4Tgf2HAERrwj0B6AfWQaDfcjAJtQ0xorONJJpEZpItV8Cl5dSeOtX7howTB
  BvBHcmyVbaW7PGNBmIM1FBKwi/fBJoawSJlslA==
  -----END CERTIFICATE-----
EOF

if [ ${FIPS_ENABLED} = "true" ]; then
	echo "Adding 'fips: true' to install-config.yaml"
	cat >> "${out}" << EOF
fips: true
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
