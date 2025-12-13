#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts conf nmstate-brex-bond command ************"

echo "NETWORK_TYPE=\"OVNKubernetes\"" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "NETWORK_CONFIG_FOLDER=/root/dev-scripts/network-configs/bond" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "ASSETS_EXTRA_FOLDER=/root/dev-scripts/network-configs/nmstate-brex-bond" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "BOND_PRIMARY_INTERFACE=true" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "EXTRA_NETWORK_NAMES=\"nmstate1 nmstate2\"" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "NMSTATE1_NETWORK_SUBNET_V4=\"192.168.221.0/24\"" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "NMSTATE1_NETWORK_SUBNET_V6=\"fd2e:6f44:5dd8:ca56::/120\"" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "NMSTATE2_NETWORK_SUBNET_V4=\"192.168.222.0/24\"" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "NMSTATE2_NETWORK_SUBNET_V6=\"fd2e:6f44:5dd8:cc56::/120\"" >> "${SHARED_DIR}/dev-scripts-additional-config"

sed -i 's/aW50ZXJmYWNlczoKLSBuYW1lOiBib25kMAogIHR5cGU6IGJvbmQKICBzdGF0ZTogdXAKICBpcHY0OgogICAgZW5hYmxlZDogZmFsc2UKICBsaW5rLWFnZ3JlZ2F0aW9uOgogICAgbW9kZTogYWN0aXZlLWJhY2t1cAogICAgb3B0aW9uczoKICAgICAgbWlpbW9uOiAnMTAwJwogICAgcG9ydDoKICAgIC0gZW5wMnMwCiAgICAtIGVucDNzMAotIG5hbWU6IGJyLWV4CiAgdHlwZTogb3ZzLWJyaWRnZQogIHN0YXRlOiB1cAogIGlwdjQ6CiAgICBlbmFibGVkOiBmYWxzZQogICAgZGhjcDogZmFsc2UKICBpcHY2OgogICAgZW5hYmxlZDogZmFsc2UKICAgIGRoY3A6IGZhbHNlCiAgYnJpZGdlOgogICAgcG9ydDoKICAgIC0gbmFtZTogYm9uZDAKICAgIC0gbmFtZTogYnItZXgKLSBuYW1lOiBici1leAogIHR5cGU6IG92cy1pbnRlcmZhY2UKICBjb3B5LW1hYy1mcm9tOiBlbnAyczAKICBzdGF0ZTogdXAKICBpcHY0OgogICAgZW5hYmxlZDogdHJ1ZQogICAgZGhjcDogdHJ1ZQogIGlwdjY6CiAgICBlbmFibGVkOiB0cnVlCiAgICBkaGNwOiB0cnVl/aW50ZXJmYWNlczoKLSBuYW1lOiBib25kMAogIHR5cGU6IGJvbmQKICBzdGF0ZTogdXAKICBpcHY0OgogICAgZW5hYmxlZDogZmFsc2UKICBsaW5rLWFnZ3JlZ2F0aW9uOgogICAgbW9kZTogYWN0aXZlLWJhY2t1cAogICAgb3B0aW9uczoKICAgICAgbWlpbW9uOiAnMTAwJwogICAgcG9ydDoKICAgIC0gZW5wMnMwCiAgICAtIGVucDZzMAotIG5hbWU6IGJyLWV4CiAgdHlwZTogb3ZzLWJyaWRnZQogIHN0YXRlOiB1cAogIGlwdjQ6CiAgICBlbmFibGVkOiBmYWxzZQogICAgZGhjcDogZmFsc2UKICBpcHY2OgogICAgZW5hYmxlZDogZmFsc2UKICAgIGRoY3A6IGZhbHNlCiAgYnJpZGdlOgogICAgcG9ydDoKICAgIC0gbmFtZTogYm9uZDAKICAgIC0gbmFtZTogYnItZXgKLSBuYW1lOiBici1leAogIHR5cGU6IG92cy1pbnRlcmZhY2UKICBjb3B5LW1hYy1mcm9tOiBlbnA2czAKICBzdGF0ZTogdXAKICBpcHY0OgogICAgZW5hYmxlZDogdHJ1ZQogICAgZGhjcDogdHJ1ZQogIGlwdjY6CiAgICBlbmFibGVkOiB0cnVlCiAgICBkaGNwOiB0cnVl/g' /root/dev-scripts/network-configs/nmstate-brex-bond/*.yml
