#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

if test ! -f "${SHARED_DIR}/proxyregion"
then
	echo "No proxyregion, so unknown AWS region, so unable to tear down ."
	exit 0
fi

REGION="$(cat "${SHARED_DIR}/proxyregion")"
PROXY_NAME="${NAMESPACE}-${JOB_NAME_HASH}"

# cleaning up after ourselves
if aws --region "${REGION}" s3api head-bucket --bucket "${PROXY_NAME}" > /dev/null 2>&1
then
  aws --region "${REGION}" s3 rb "s3://${PROXY_NAME}" --force
fi

STACK_NAME="${PROXY_NAME}-proxy"

# collect logs from the proxy here
if [ -f "${SHARED_DIR}/proxyip" ]; then
  proxy_ip="$(cat "${SHARED_DIR}/proxyip")"

  if ! whoami &> /dev/null; then
    if [ -w /etc/passwd ]; then
      echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    fi
  fi
  eval "$(ssh-agent)"
  ssh-add "${CLUSTER_PROFILE_DIR}/ssh-privatekey"
  ssh -A -o PreferredAuthentications=publickey -o StrictHostKeyChecking=false -o UserKnownHostsFile=/dev/null "core@${proxy_ip}" 'journalctl -u squid' > "${ARTIFACT_DIR}/squid.service"
fi

aws --region "${REGION}" cloudformation delete-stack --stack-name "${STACK_NAME}" &
wait "$!"

aws --region "${REGION}" cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}" &
wait "$!"
