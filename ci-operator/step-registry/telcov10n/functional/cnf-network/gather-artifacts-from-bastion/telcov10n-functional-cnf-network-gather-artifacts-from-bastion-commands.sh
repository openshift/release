#!/bin/bash
set -e
set -o pipefail

PROJECT_DIR=/tmp

echo "Set CLUSTER_NAME env var"
if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
    CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi
export CLUSTER_NAME=${CLUSTER_NAME}
echo CLUSTER_NAME="${CLUSTER_NAME}"

echo "Set bastion ssh configuration"
cat /var/group_variables/common/all/ansible_ssh_private_key > $PROJECT_DIR/temp_ssh_key
chmod 600 $PROJECT_DIR/temp_ssh_key
BASTION_IP=$(cat /var/host_variables/"${CLUSTER_NAME}"/bastion/ansible_host)
BASTION_USER=$(cat /var/group_variables/common/all/ansible_user)

echo "Create artifacts directory"
mkdir "${PROJECT_DIR}"/artifacts

echo "Store content from phase 1 run in SHARED_DIR"
scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /tmp/temp_ssh_key "${BASTION_USER}@${BASTION_IP}":~/build-artifiacts/* "${PROJECT_DIR}"/artifacts/

echo "Gather inventory files"
for file in "${PROJECT_DIR}"/artifacts/*; do
  [[ "$file" == *.xml ]] && continue
  cp "${file}" "${SHARED_DIR}"/
done

echo "Copy reports for reporter step"
cp "${PROJECT_DIR}"/artifacts/junit_*.xml "${SHARED_DIR}"/ 2>/dev/null || true
cp "${PROJECT_DIR}"/artifacts/report_polarion.xml "${SHARED_DIR}/polarion_report_polarion.xml" 2>/dev/null || true

echo "Combine per-suite cnf-gotests JUnit into polarion_cnfgotests.xml for reporter step"
python3 - "${PROJECT_DIR}/artifacts" "${SHARED_DIR}/polarion_cnfgotests.xml" << 'PYEOF'
import re, sys, xml.etree.ElementTree as ET, glob, os
src_dir, out_file = sys.argv[1], sys.argv[2]
def strip(s):
    s = re.sub(r'<system-err>.*?</system-err>', '', s, flags=re.DOTALL)
    return re.sub(r'<system-out>.*?</system-out>', '', s, flags=re.DOTALL)
root = ET.Element('testsuite', {'name': 'cnf-gotests'})
for f in sorted(glob.glob(os.path.join(src_dir, '*_suite_test.xml'))):
    try:
        tree = ET.fromstring(strip(open(f).read()))
        for suite in ([tree] if tree.tag == 'testsuite' else list(tree)):
            if suite.tag == 'testsuite':
                for tc in suite.findall('testcase'):
                    root.append(tc)
    except ET.ParseError:
        pass
ET.ElementTree(root).write(out_file, encoding='unicode', xml_declaration=True)
PYEOF

mkdir "${ARTIFACT_DIR}/junit"
for file in "${PROJECT_DIR}"/artifacts/*.xml; do
  [[ $(basename "$file") == "report_polarion.xml" ]] && continue
  echo "${file}"
  cp "${file}" "${ARTIFACT_DIR}"/junit/
done
