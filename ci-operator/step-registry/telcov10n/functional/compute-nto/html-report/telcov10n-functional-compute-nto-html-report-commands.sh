#!/bin/bash
echo "Generate HTML reports from JUnit files"

script_url=https://raw.githubusercontent.com/openshift-kni/telco5gci/refs/heads/master/j2html.py
requirements_url=https://raw.githubusercontent.com/openshift-kni/telco5gci/refs/heads/master/requirements.txt

echo "Install dependencies"
pip install -r ${requirements_url}

echo "Download script"
curl -o /tmp/j2html.py ${script_url}

python3 /tmp/j2html.py --format xml ${SHARED_DIR}/*.xml --output ${ARTIFACT_DIR}/nto_test_report.html 2>/dev/null || echo "No JUnit files found to generate HTML report"