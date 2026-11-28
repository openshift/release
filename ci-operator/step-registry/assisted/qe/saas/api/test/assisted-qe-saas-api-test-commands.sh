#!/bin/bash
set -euo pipefail
source "${SHARED_DIR}/qe-ssh.sh"
qe_remote test "$QE_TEST_TIMEOUT" <<'REMOTE'
source "$WORKSPACE/api.env"
source "$VENV/bin/activate"
cd "$BASE_REPO_DIR/linchpin-workspace"
status=0
ansible-playbook -i inventories/ocp-edge.inventory hooks/ansible/ocp-edge-setup/assisted-installer.yaml \
    --vault-password-file "$OCM_VAULT_CRED" \
    -e @hooks/ansible/ocp-edge-setup/extravars.yaml \
    -e run_cucushift=false -e @hooks/ansible/ocp-edge-setup/vault_files/ocp_secrets_ai_saas.yaml \
    -e ocp_deployment_type=None -e ansible_user=kni || status=$?

shopt -s nullglob
reports=(/var/tmp/assisted/assisted-test-infra/reports/unittest*.xml)
for report in "${reports[@]}"; do
    # Read root-owned reports but create the private copy as the SSH user.
    # shellcheck disable=SC2024
    sudo -n cat "$report" > "$WORKSPACE/results/${report##*/}"
done
if [[ -f /var/tmp/assisted/assisted-test-infra/failed ]]; then
    touch "$WORKSPACE/results/failed"
fi
"$QE_PYTHON" "$WORKSPACE/results.py" check "$WORKSPACE" || status=1
exit "$status"
REMOTE
