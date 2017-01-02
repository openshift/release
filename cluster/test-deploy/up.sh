#!/bin/bash
set -euo pipefail

# accepts: BUILD_NUMBER DATA_DIR [URL PLAYBOOK | URL]
build=$1
data=$2
url=${3-}

# provide simple defaulting of playbooks
playbook="${4:-playbooks/provision.yaml}"
if [[ -z "${3-}" && -z "${4-}" ]]; then
  playbook="playbooks/deprovision.yaml"
fi

# start a container with the custom playbook inside it
docker rm gce-pr-$build &>/dev/null || true
args=""
if [[ -n "${OPENSHIFT_ANSIBLE_REPO-}" ]]; then
  docker volume rm gce-pr-$build-volume &>/dev/null || true
  docker volume create --name gce-pr-$build-volume >/dev/null
  args="-v gce-pr-$build-volume:/usr/share/ansible/openshift-ansible "
fi
docker create -e "PR_NUMBER=pr${build}" -e "PR_REPO_URL=${url}" --name gce-pr-$build $args openshift/origin-gce:latest ansible-playbook "${@:5}" "${playbook}" >/dev/null
tar -c -C "${data}" . | docker cp - gce-pr-$build:/usr/share/ansible/openshift-ansible-gce/playbooks/files
if [[ -n "${OPENSHIFT_ANSIBLE_REPO-}" ]]; then
  tar -c -C "${OPENSHIFT_ANSIBLE_REPO}" . | docker cp - gce-pr-$build:/usr/share/ansible/openshift-ansible/
fi
docker start -a gce-pr-$build
docker cp gce-pr-$build:/tmp/admin.kubeconfig admin.kubeconfig &>/dev/null || true
