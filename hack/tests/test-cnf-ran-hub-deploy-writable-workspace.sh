#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
commands_script="${repo_root}/ci-operator/step-registry/telcov10n/functional/cnf-ran/hub-deploy/telcov10n-functional-cnf-ran-hub-deploy-commands.sh"
podman_cmd="${PODMAN:-podman}"
test_image="${TEST_IMAGE:-quay.io/openshift/ci-public:ci_ci-operator-checkconfig_latest}"

command -v "${podman_cmd}" >/dev/null
"${podman_cmd}" image exists "${test_image}"

test_dir="$(mktemp -d "${TMPDIR:-/tmp}/hub-deploy-workspace-test.XXXXXX")"
trap 'rm -rf "${test_dir}"' EXIT
mkdir -p "${test_dir}/source/playbooks" "${test_dir}/source/inventories/ocp-deployment"
mkdir -p "${test_dir}/group_variables/common"/{all,bastions,hypervisors}
mkdir -p "${test_dir}/group_variables/kni-qe-134"/{masters,nodes}
mkdir -p "${test_dir}/host_variables/kni-qe-134"/{master0,bastion,hypervisor}
mkdir -p "${test_dir}/fakebin" "${test_dir}/shared"
chmod 755 "${test_dir}"
chmod 777 "${test_dir}/shared"

touch "${test_dir}/source/playbooks/deploy-ocp-sno.yml"
touch "${test_dir}/source/inventories/ocp-deployment/build-inventory.py"
printf 'source fixture\n' > "${test_dir}/source/source-marker"
printf 'ciuser\n' > "${test_dir}/group_variables/common/all/ansible_user"
printf 'fake-key\n' > "${test_dir}/group_variables/common/all/ansible_ssh_private_key"
printf '192.0.2.10\n' > "${test_dir}/host_variables/kni-qe-134/bastion/ansible_host"

cat > "${test_dir}/fakebin/ansible-playbook" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
[[ "${PWD}" == /tmp/eco-ci-cd.* ]]
[[ ! -w /eco-ci-cd ]]
[[ ! -d /eco-ci-cd/inventories/ocp-deployment/group_vars ]]
[[ -f ./playbooks/deploy-ocp-sno.yml ]]
grep -Fq "ansible_user: 'ciuser'" ./inventories/ocp-deployment/group_vars/all
grep -Fq "ansible_host: '192.0.2.10'" ./inventories/ocp-deployment/host_vars/bastion
for inventory in all bastions hypervisors masters nodes; do
  [[ -f "./inventories/ocp-deployment/group_vars/${inventory}" ]]
done
for inventory in bastion hypervisor master0; do
  [[ -f "./inventories/ocp-deployment/host_vars/${inventory}" ]]
done
[[ "$*" == *"release=4.18 cluster_name=kni-qe-134"* ]]
printf '%s\n' "${PWD}" > /shared/ansible-cwd
SCRIPT
cat > "${test_dir}/fakebin/ssh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == *"ciuser@192.0.2.10"* ]]
printf '4.18.0\n'
SCRIPT
chmod 755 "${test_dir}/fakebin/ansible-playbook" "${test_dir}/fakebin/ssh"
chmod -R a+rX "${test_dir}/source" "${test_dir}/group_variables" \
  "${test_dir}/host_variables" "${test_dir}/fakebin"

container_args=(
  --rm
  --user 1001:1001
  --volume "${test_dir}/source:/eco-ci-cd:ro"
  --volume "${test_dir}/group_variables:/var/group_variables:ro"
  --volume "${test_dir}/host_variables:/var/host_variables:ro"
  --volume "${test_dir}/fakebin:/fakebin:ro"
  --volume "${test_dir}/shared:/shared:rw"
  --volume "${commands_script}:/test-commands.sh:ro"
  --env PATH=/fakebin:/usr/bin:/bin
  --env TMPDIR=/tmp
  --env SHARED_DIR=/shared
  --env CLUSTER_NAME=kni-qe-134
  --env VERSION=4.18
  --env ARCH=x86_64
  --env DISABLE_INSIGHTS=true
  --env MULTISTAGE_PARAM_OVERRIDE_RELEASE_AGE_MAX_DAYS=7
)

if "${podman_cmd}" run "${container_args[@]}" --entrypoint /bin/bash \
  "${test_image}" -c 'exec /bin/bash /test-commands.sh' \
  > "${test_dir}/default.log" 2>&1; then
  echo "default workspace unexpectedly wrote to read-only source" >&2
  exit 1
fi
grep -Fq "/eco-ci-cd/inventories/ocp-deployment/group_vars" "${test_dir}/default.log"

"${podman_cmd}" run "${container_args[@]}" \
  --env COPY_ECO_CI_CD_TO_TEMP=true \
  --entrypoint /bin/bash "${test_image}" -c 'exec /bin/bash /test-commands.sh'
[[ "$(cat "${test_dir}/shared/cluster_version")" == 4.18.0 ]]
[[ "$(cat "${test_dir}/shared/ansible-cwd")" == /tmp/eco-ci-cd.* ]]
[[ "$(cat "${test_dir}/source/source-marker")" == "source fixture" ]]
[[ ! -d "${test_dir}/source/inventories/ocp-deployment/group_vars" ]]
echo "Writable workspace behavior passed; deployment commands were stubbed."
