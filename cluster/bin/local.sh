#!/bin/bash
set -euo pipefail

ctr=gce-build-"$( date +%Y%m%d-%H%M%S )"

function cleanup() {
  docker kill $ctr &>/dev/null || true
  docker rm $ctr &>/dev/null || true
}
trap cleanup EXIT
cleanup

# start a container with the custom playbook inside it
opts="--mode=ug+rwX --owner=0 --group=0"
args=""
if [[ -n "${OPENSHIFT_ANSIBLE_REPO-}" ]]; then
  docker volume rm $ctr-volume &>/dev/null || true
  docker volume create --name $ctr-volume >/dev/null
  args="-v $ctr-volume:/usr/share/ansible/openshift-ansible "
fi

if [[ $# -eq 0 ]]; then
  args+="-it "
  docker create --name "$ctr" -v /var/tmp -e "INSTANCE_PREFIX=${INSTANCE_PREFIX}" -e "OPENSHIFT_ANSIBLE_COMMIT=${OPENSHIFT_ANSIBLE_COMMIT-}" $args "${OPENSHIFT_ANSIBLE_GCE_IMAGE:-openshift/origin-gce:latest}" /bin/bash >/dev/null
else
  docker create --name "$ctr" -v /var/tmp -e "INSTANCE_PREFIX=${INSTANCE_PREFIX}" -e "OPENSHIFT_ANSIBLE_COMMIT=${OPENSHIFT_ANSIBLE_COMMIT-}" $args "${OPENSHIFT_ANSIBLE_GCE_IMAGE:-openshift/origin-gce:latest}" "$@" >/dev/null
fi

tar ${opts} -c . | docker cp - $ctr:/usr/share/ansible/openshift-ansible-gce/playbooks/files
if [[ -n "${OPENSHIFT_ANSIBLE_REPO-}" ]]; then
  tar ${opts} -c -C "${OPENSHIFT_ANSIBLE_REPO}" . | docker cp - $ctr:/usr/share/ansible/openshift-ansible/
fi

if [[ $# -eq 0 ]]; then
  docker start -ai "${ctr}"
else
  docker start -a "${ctr}"
fi
docker cp "$ctr":/tmp/admin.kubeconfig admin.kubeconfig &>/dev/null || true
