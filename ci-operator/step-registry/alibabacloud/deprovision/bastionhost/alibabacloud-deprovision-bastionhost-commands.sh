#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ ! -f "${SHARED_DIR}/destroy-bastion.sh" ]; then
  echo "No 'destroy-bastion.sh' found, aborted." && exit 0
fi

workdir="/tmp/installer"
mkdir -p "${workdir}"
pushd "${workdir}"

if ! [ -x "$(command -v aliyun)" ]; then
  echo "$(date -u --rfc-3339=seconds) - Downloading 'aliyun' as it's not intalled..."
  curl -sSL "https://aliyuncli.alicdn.com/aliyun-cli-linux-latest-amd64.tgz" --output aliyun-cli-linux-latest-amd64.tgz && \
  tar -xvf aliyun-cli-linux-latest-amd64.tgz && \
  rm -f aliyun-cli-linux-latest-amd64.tgz
  ALIYUN_BIN="${workdir}/aliyun"
else
  ALIYUN_BIN="$(which aliyun)"
fi

# copy the creds to the SHARED_DIR
if test -f "${CLUSTER_PROFILE_DIR}/alibabacreds.ini" 
then
  echo "$(date -u --rfc-3339=seconds) - Copying creds from CLUSTER_PROFILE_DIR to SHARED_DIR..."
  cp ${CLUSTER_PROFILE_DIR}/alibabacreds.ini ${SHARED_DIR}
  cp ${CLUSTER_PROFILE_DIR}/config ${SHARED_DIR}
  cp ${CLUSTER_PROFILE_DIR}/envvars ${SHARED_DIR}
else
  echo "$(date -u --rfc-3339=seconds) - Copying creds from /var/run/vault/alibaba/ to SHARED_DIR..."
  cp /var/run/vault/alibaba/alibabacreds.ini ${SHARED_DIR}
  cp /var/run/vault/alibaba/config ${SHARED_DIR}
  cp /var/run/vault/alibaba/envvars ${SHARED_DIR}
fi

source ${SHARED_DIR}/envvars

echo "$(date -u --rfc-3339=seconds) - 'aliyun' authentication..."
ALIYUN_PROFILE="${SHARED_DIR}/config"
${ALIYUN_BIN} configure set --config-path "${ALIYUN_PROFILE}"

## Destroying DNS resources of mirror registry
if [[ -f "${SHARED_DIR}/destroy-mirror-dns.sh" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Destroying DNS resources of mirror registry..."
  sh "${SHARED_DIR}/destroy-mirror-dns.sh"
fi

## Destroy the SSH bastion
echo "$(date -u --rfc-3339=seconds) - Destroying the bastion host..."
sh "${SHARED_DIR}/destroy-bastion.sh"

popd
rm -rf "${workdir}"
