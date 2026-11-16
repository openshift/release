#!/bin/bash
set -euo pipefail

if [[ -f "${SHARED_DIR}/skip.txt" ]]; then
  exit 0
fi

cd /eco-ci-cd
mkdir -p inventories/cnf/{group_vars,host_vars}
cp "${SHARED_DIR}/all" inventories/cnf/group_vars/all.yaml
cp "${SHARED_DIR}/bastions" inventories/cnf/group_vars/bastions.yaml
cp "${SHARED_DIR}/bastion" inventories/cnf/host_vars/bastion.yaml

# Retrieve the kubeconfig and prepare the registry before removing the spoke from ACM.
ansible-playbook playbooks/ran/ibu-prepare-spoke-sno.yml \
  -i inventories/cnf/switch-config.yaml \
  -e "hub_cluster=${CLUSTER_NAME} spoke_cluster=${SEED_SPOKE_CLUSTER}"

ansible-playbook playbooks/ran/ibu-prune-argocd-apps.yml \
  -i inventories/cnf/switch-config.yaml \
  -e "hub_kubeconfig=/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig" \
  -e "spoke_cluster=${SEED_SPOKE_CLUSTER}"

SEED_IMAGE="${MIRROR_REGISTRY}/arm-ibx/seed:${VERSION}"
ECO_GOTESTS_ENV_VARS="-e ECO_CNF_RAN_SKIP_TLS_VERIFY=true"
ECO_GOTESTS_ENV_VARS+=" -e ECO_LCA_IBGU_SEED_IMAGE=${SEED_IMAGE}"
ECO_GOTESTS_ENV_VARS+=" -e ECO_LCA_IBU_CNF_KUBECONFIG_TARGET_SNO=/kubeconfig/kubeconfig"

# Generate the test script with the disconnected registry as its destination.
ansible-playbook playbooks/deploy-run-eco-gotests.yaml \
  -i inventories/cnf/switch-config.yaml \
  -e "kubeconfig=/tmp/${SEED_SPOKE_CLUSTER}-kubeconfig" \
  -e 'eco_gotest_dir=/tmp/eco_gotests_seedgeneration' \
  -e 'features=seedgeneration labels=!no-container eco_gotests_tag=latest' \
  -e 'eco_worker_label="" eco_cnf_core_net_switch_user="" eco_cnf_core_net_switch_pass=""' \
  -e "additional_test_env_variables=\"${ECO_GOTESTS_ENV_VARS}\""

seed_rc=0
ansible-playbook playbooks/ran/ibu-run-seedgeneration.yml \
  -i inventories/cnf/switch-config.yaml \
  -e "spoke_cluster=${SEED_SPOKE_CLUSTER}" \
  -e 'eco_gotest_dir=/tmp/eco_gotests_seedgeneration' || seed_rc=$?

# Collect JUnit XMLs, console logs, and k8sreporter files even if tests fail.
ansible-playbook playbooks/collect-eco-gotests-artifacts.yaml \
  -i inventories/cnf/switch-config.yaml \
  -e 'eco_gotests_features=seedgeneration' \
  -e "artifact_dir=${ARTIFACT_DIR}" \
  -e "hub_clusterconfigs_path=/home/telcov10n/project/generated/${CLUSTER_NAME}" \
  || echo "Warning: seed-generation artifact collection failed"

if [[ "$seed_rc" -eq 0 ]]; then
  echo "Seed image: ${SEED_IMAGE}"
fi
exit "$seed_rc"
