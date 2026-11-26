#!/bin/bash
set -euo pipefail
# Post runs even when setup failed before obtaining a remote workspace.
[[ -s "${SHARED_DIR}/qe-workspace" ]] || exit 0
source "${SHARED_DIR}/qe-ssh.sh"
# A timed-out/disconnected test must stop before reporting or lease release.
qe_stop
status=0
qe_remote gather 50m <<'REMOTE' || status=$?
mkdir -p "$WORKSPACE/results"
mkdir -p "$HOME/test_artifacts"
cp "$WORKSPACE/logs/"*.log "$HOME/test_artifacts/" 2>/dev/null || true
cp "$WORKSPACE/revisions.txt" "$WORKSPACE/results/" 2>/dev/null || true
[[ -f "$WORKSPACE/prepared" ]] || exit 0
source "$VENV/bin/activate"
reports=/var/tmp/assisted/assisted-test-infra/reports
sudo cp "$reports"/unittest*.xml "$WORKSPACE/results/" 2>/dev/null || true
sudo chown -R kni:kni "$WORKSPACE/results"
mkdir -p "$HOME/test_artifacts"
sudo cp -r /root/test_artifacts/. "$HOME/test_artifacts/" 2>/dev/null || true
sudo chown -R kni:kni "$HOME/test_artifacts"
cp "$WORKSPACE/results/"*.xml "$HOME/test_artifacts/" 2>/dev/null || true
for repo in assisted-test-infra kni-assisted-installer-auto; do
    if [[ -d "/var/tmp/assisted/$repo/.git" ]]; then
        printf '%s %s\n' "$repo" "$(sudo git -C "/var/tmp/assisted/$repo" rev-parse HEAD)" >> "$WORKSPACE/results/revisions.txt"
    fi
done
# Preserve logs privately; never archive decrypted extravars or the vault keys.
find "$HOME/test_artifacts" -maxdepth 1 -type f \( -name '*.zip' -o -name 'versions.log' \) \
    -exec cp '{}' "$WORKSPACE/results/" \;
[[ "$QE_PUBLISH_RESULTS" == true ]] || exit 0

# Each reporter is independent, so a failure cannot prevent the other uploads.
cat > "$WORKSPACE/report-datahub.sh" <<'REPORT'
set -euo pipefail
source "$WORKSPACE/job.env"
source "$VENV/bin/activate"
cd "$BASE_REPO_DIR/linchpin-workspace"
export PROJECT_NAME=$JOB_NAME
cp "$WORKSPACE/results/"report-*.log "$HOME/test_artifacts/" 2>/dev/null || true
ansible-playbook -i localhost, --connection=local hooks/ansible/ocp-edge-setup/upload-logs-to-datahub.yaml \
    --vault-password-file "$OCM_VAULT_CRED" -e @hooks/ansible/ocp-edge-setup/extravars.yaml \
    -e @hooks/ansible/ocp-edge-setup/vault_files/datahub_secret.yaml
REPORT
cat > "$WORKSPACE/report-portal.sh" <<'REPORT'
set -euo pipefail
source "$WORKSPACE/job.env"
source "$VENV/bin/activate"
mkdir -p "$WORKSPACE/xml_results"
cp "$WORKSPACE/results/"unittest*.xml "$WORKSPACE/xml_results/"
vaultcontent=$(ansible-vault view --vault-password-file "$OCM_VAULT_CRED" \
    "$BASE_REPO_DIR/linchpin-workspace/hooks/ansible/ocp-edge-setup/vault_files/report-portal.yml")
username=$(printf '%s\n' "$vaultcontent" | awk -F': ' '/username/ {print $2}')
password=$(printf '%s\n' "$vaultcontent" | awk -F': ' '/password/ {print $2}')
api_version=$(awk '/^API:/ {print $2}' "$HOME/test_artifacts/versions.log")
cd "$WORKSPACE"
bash "$BASE_REPO_DIR/tools/rp-files/report_portal_data_router.sh" \
    "$PROFILE_NAME" "$OCP_MINOR_VERSION" "$WORKSPACE" "$BUILD_URL" "$username" "$password" "$api_version"
REPORT
cat > "$WORKSPACE/report-polarion.sh" <<'REPORT'
set -euo pipefail
source "$WORKSPACE/job.env"
source "$VENV/bin/activate"
shopt -s nullglob
reports=("$WORKSPACE/results/"unittest*.xml)
(( ${#reports[@]} > 0 ))
# The existing reporter accepts a comma-separated list. Include the original
# unittest_*.xml names instead of relying on Jenkins' rename to unittest.xml.
junit_files=$(IFS=,; printf '%s' "${reports[*]}")
mkdir -p "$WORKSPACE/polarion-reporting"
cd "$WORKSPACE/polarion-reporting"
git clone --branch master https://gitlab.cee.redhat.com/ocp-edge-qe/kni-qe-ci-tools.git
git -C kni-qe-ci-tools checkout --detach 92d81f56057af27987ed0f494b99125d6f90d0bf
git -C kni-qe-ci-tools rev-parse HEAD > "$WORKSPACE/results/polarion-revision.txt"
python -m venv "$WORKSPACE/venv-reporting"
source "$WORKSPACE/venv-reporting/bin/activate"
pip install 'setuptools<58' 'xunitparser>=1.3.3' junit_xml bs4 teflo==2.1 \
    git+https://gitlab.cee.redhat.com/ccit/teflo/plugins/teflo_polarion_plugin \
    git+https://gitlab.cee.redhat.com/ccit/teflo/plugins/teflo_rppreproc_plugin
ansible-playbook -i kni-qe-ci-tools/ci-polarion-reporting/inventory \
    kni-qe-ci-tools/ci-polarion-reporting/teflo_reporting.yml \
    -e "polarion_test_run_id=$ASSISTED_POLARION_TESTRUN_ID" \
    -e "junit_xml_files=$junit_files" -e "working_dir=$PWD" \
    -e "ansible_python_interpreter=$SYSTEM_PYTHON"
data_folder=$(mktemp -d -p . teflo.XXXXXX)
for task in provision execute report; do
    teflo run --data-folder "$data_folder" -s scenario.yml -t "$task"
done
REPORT
status=0
for reporter in portal polarion datahub; do
    rc=0
    timeout --kill-after=30s 12m bash "$WORKSPACE/report-$reporter.sh" \
        > "$WORKSPACE/results/report-$reporter.log" 2>&1 || rc=$?
    printf '%s: %s\n' "$reporter" "$rc" >> "$WORKSPACE/results/report-status.txt"
    [[ "$rc" == 0 ]] || status=1
done
exit "$status"
REMOTE
work=$(cat "${SHARED_DIR}/qe-workspace")
# The repository's Prow artifacts are public. Strip properties, output, tracebacks
# and parametrized case values; originals stay internal for RP/Polarion/Datahub.
printf -v command 'python3 - %q' "$work"
qe_ssh "$command" <<'PY' || status=1
from pathlib import Path
import re
import shutil
import sys
import xml.etree.ElementTree as ET
work = Path(sys.argv[1])
public = work / 'public'
public.mkdir(exist_ok=True)
for report in (work / 'results').glob('unittest*.xml'):
    original = ET.parse(report)
    suite = ET.Element('testsuite', name='assisted-regression0')
    for index, case in enumerate(original.iter('testcase')):
        # Test identifiers only, no parameters/values or arbitrary XML attributes.
        name = re.sub(r'[^a-zA-Z0-9_.:-]', '_', case.get('name', 'test').split('[')[0])
        item = ET.SubElement(suite, 'testcase', name=f'{name}-{index}', classname='assisted.regression0')
        for tag in ('failure', 'error', 'skipped'):
            if case.find(tag) is not None:
                ET.SubElement(item, tag, message='See internal Datahub/Report Portal for details')
    suite.set('tests', str(len(suite)))
    for tag, attr in [('failure', 'failures'), ('error', 'errors'), ('skipped', 'skipped')]:
        suite.set(attr, str(len(suite.findall(f'testcase/{tag}'))))
    ET.ElementTree(suite).write(public / ('junit_' + report.name), encoding='utf-8', xml_declaration=True)
for name in ('revisions.txt', 'polarion-revision.txt', 'report-status.txt'):
    path = work / 'results' / name
    if path.exists():
        shutil.copyfile(path, public / name)
PY
qe_ssh "tar -C '$work/public' -cf - ." | tar -C "${ARTIFACT_DIR}" -xf - || status=1
exit "$status"
