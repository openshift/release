#!/bin/bash

set -o nounset
set -o errext
set -o pipefail

export PATH=$PATH:/tmp/shared

echo "Gathering installer artifacts ..."
# we don't have jq, so the python equivalent of
# jq '.modules[].resources."aws_instance.bootstrap".primary.attributes."public_ip" | select(.)'
bootstrap_ip=$(python -c \
    'import sys, json; d=reduce(lambda x,y: dict(x.items() + y.items()), map(lambda x: x["resources"], json.load(sys.stdin)["modules"])); k="aws_instance.bootstrap"; print d[k]["primary"]["attributes"]["public_ip"] if k in d else ""' \
    < ${ARTIFACT_DIR}/installer/terraform.tfstate
)

if [ -n "${bootstrap_ip}" ]
then
  for service in bootkube openshift kubelet crio
  do
      curl \
          --insecure \
          --silent \
          --connect-timeout 5 \
          --retry 3 \
          --cert ${ARTIFACT_DIR}/installer/tls/journal-gatewayd.crt \
          --key ${ARTIFACT_DIR}/installer/tls/journal-gatewayd.key \
          --url "https://${bootstrap_ip}:19531/entries?_SYSTEMD_UNIT=${service}.service" > "${ARTIFACT_DIR}/bootstrap/${service}.service"
  done
  if ! whoami &> /dev/null; then
    if [ -w /etc/passwd ]; then
      echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    fi
  fi
  eval $(ssh-agent)
  ssh-add /etc/openshift-installer/ssh-privatekey
  ssh -A -o PreferredAuthentications=publickey -o StrictHostKeyChecking=false -o UserKnownHostsFile=/dev/null core@${bootstrap_ip} /bin/bash -x /usr/local/bin/installer-gather.sh
  scp -o PreferredAuthentications=publickey -o StrictHostKeyChecking=false -o UserKnownHostsFile=/dev/null core@${bootstrap_ip}:log-bundle.tar.gz ${ARTIFACT_DIR}/installer/bootstrap-logs.tar.gz
fi