#!/bin/bash
set -euo pipefail

# accepts: BUILD_NUMBER DATA_DIR [URL PLAYBOOK | URL]
build=$1
data=$2
url=${3-}

# provide simple defaulting of playbooks
playbook="${4:-playbooks/launch.yaml}"
if [[ -z "${3-}" && -z "${4-}" ]]; then
  playbook="playbooks/terminate.yaml"
fi

ctr=gce-pr-$build
opts="--mode=ug+rwX --owner=0 --group=0"

# start a container with the custom playbook inside it
docker rm $ctr &>/dev/null || true
args=""
if [[ -n "${OPENSHIFT_ANSIBLE_REPO-}" ]]; then
  docker volume rm $ctr-volume &>/dev/null || true
  docker volume create --name $ctr-volume >/dev/null
  args="-v $ctr-volume:/usr/share/ansible/openshift-ansible "
fi
docker create -e "OPENSHIFT_ANSIBLE_COMMIT=${OPENSHIFT_ANSIBLE_COMMIT-}" -e "PR_NUMBER=pr${build}" -e "PR_REPO_URL=${url}" --name $ctr $args openshift/origin-gce:latest ansible-playbook "${@:5}" "${playbook}" >/dev/null
tar ${opts} -c -C "${data}" . | docker cp - $ctr:/usr/share/ansible/openshift-ansible-gce/playbooks/files
if [[ -n "${OPENSHIFT_ANSIBLE_REPO-}" ]]; then
  tar ${opts} -c -C "${OPENSHIFT_ANSIBLE_REPO}" . | docker cp - $ctr:/usr/share/ansible/openshift-ansible/
fi
docker start -a $ctr
docker cp $ctr:/tmp/admin.kubeconfig admin.kubeconfig &>/dev/null || true
