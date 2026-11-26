#!/bin/bash
set -euo pipefail
source "${SHARED_DIR}/qe-ssh.sh"
qe_remote test 11h50m <<'REMOTE'
source "$VENV/bin/activate"
cd "$BASE_REPO_DIR/linchpin-workspace"
status=0
ansible-playbook -i inventories/ocp-edge.inventory hooks/ansible/ocp-edge-setup/assisted-installer.yaml \
    --vault-password-file "$OCM_VAULT_CRED" \
    -e @hooks/ansible/ocp-edge-setup/extravars.yaml \
    -e run_cucushift=false -e @hooks/ansible/ocp-edge-setup/vault_files/ocp_secrets_ai_saas.yaml \
    -e ocp_deployment_type=None -e ansible_user=kni || status=$?
# The existing playbook ignores make test_parallel's failure; never trust only rc.
python3 - <<'PY' || status=1
from pathlib import Path
import xml.etree.ElementTree as ET
root = Path('/var/tmp/assisted/assisted-test-infra')
assert not (root / 'failed').exists(), 'Ansible recorded a failed API test run'
reports = list((root / 'reports').glob('unittest*.xml'))
assert reports, 'No API JUnit reports were produced'
executed = 0
for report in reports:
    tree = ET.parse(report)
    assert not tree.findall('.//failure') and not tree.findall('.//error'), 'API JUnit contains failures/errors'
    for suite in tree.iter('testsuite'):
        assert int(suite.get('failures', 0)) == 0 and int(suite.get('errors', 0)) == 0, 'API suite failed'
    executed += sum(case.find('skipped') is None for case in tree.iter('testcase'))
assert executed, 'No API test cases executed (empty/all-skipped reports)'
print('API reports verified:', len(reports), 'files,', executed, 'executed cases')
PY
exit "$status"
REMOTE
