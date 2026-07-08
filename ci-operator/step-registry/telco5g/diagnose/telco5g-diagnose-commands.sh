#!/bin/bash

set -o nounset
set -o pipefail

echo "************ telco5g diagnose step ************"
# Fix user IDs in a container
~/fix_uid.sh

# Build a unique prefix for log files: last part of job name after "e2e-", plus timestamp
JOB_NAME_FULL="${JOB_NAME:-unknown}"
if [[ "$JOB_NAME_FULL" =~ e2e-(.*) ]]; then
    JOB_SUFFIX="${BASH_REMATCH[1]}"
else
    JOB_SUFFIX="$JOB_NAME_FULL"
fi
LOG_PREFIX="${JOB_SUFFIX}-$(date +%Y-%m-%d-%H-%M)"
echo "Log prefix: ${LOG_PREFIX}"
JOB_URL=""
if [[ "$JOB_NAME_FULL" == *"rehearse"* ]]; then
    JOB_URL="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/pr-logs/pull/openshift_release/${PULL_NUMBER:-}/${JOB_NAME_FULL}/${BUILD_ID:-}/"
else
    JOB_URL=" https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/logs/${JOB_NAME_FULL}/${BUILD_ID:-}/"
fi


SSH_PKEY_PATH=/var/run/ci-key/cikey
SSH_PKEY=~/key
cp $SSH_PKEY_PATH $SSH_PKEY
chmod 600 $SSH_PKEY

# Find the diagnose env vars file
DIAGNOSE_FILE=""
for f in "${SHARED_DIR}"/diagnose-telco5g-*; do
    [[ -f "$f" ]] || continue
    DIAGNOSE_FILE="$f"
    break
done

if [[ -z "$DIAGNOSE_FILE" ]]; then
    echo "No failures detected (no diagnose env vars file). Skipping diagnostics."
    exit 0
fi

echo "Found diagnose file: $DIAGNOSE_FILE"
# shellcheck source=/dev/null
source "$DIAGNOSE_FILE"

STEP_NAME="${STEP_NAME:-unknown}"

# Decompress log if gzipped
for gz in "${SHARED_DIR}/tests-output.log.gz" "${SHARED_DIR}/setup-output.log.gz"; do
    if [[ -f "$gz" ]]; then
        gunzip -f "$gz" 2>/dev/null || true
    fi
done

# Determine which log to use
if [[ -f "${SHARED_DIR}/tests-output.log" ]]; then
    LOG_FILE="${SHARED_DIR}/tests-output.log"
elif [[ -f "${SHARED_DIR}/setup-output.log" ]]; then
    LOG_FILE="${SHARED_DIR}/setup-output.log"
else
    LOG_FILE=""
fi

# Common header for all prompts
PROMPT_HEADER="JOB_NAME: ${JOB_NAME:-unknown}
step_name: ${STEP_NAME}
Openshift_version: ${T5CI_VERSION:-unknown}
JOB_TYPE: ${T5CI_JOB_TYPE:-unknown}"

# Generate the prompt body based on diagnose file name
DIAGNOSE_BASENAME=$(basename "$DIAGNOSE_FILE")

if [[ "$DIAGNOSE_BASENAME" == "diagnose-telco5g-cluster-setup.early" ]]; then
    PROMPT_BODY="The standard Multi-Node OpenShift (MNO) baremetal cluster installation failed early.
The cluster was being installed using kcli and ansible playbooks on baremetal nodes.
Analyze the setup log below to identify the root cause of the installation failure.
Look for initialization errors, environment setup failures, ansible task failures,
network connectivity issues, node provisioning errors, or OpenShift installer errors.
The log ot failed step is in /tmp/logfile. Provide a summary of what went wrong and suggest fixes."

elif [[ "$DIAGNOSE_BASENAME" == "diagnose-telco5g-cluster-setup" ]]; then
    PROMPT_BODY="The standard Multi-Node OpenShift (MNO) baremetal cluster installation failed.
Cluster: ${CLUSTER_NAME:-unknown}, Kcli plan: ${PLAN_NAME:-unknown}
The cluster was being installed using kcli and ansible playbooks on baremetal nodes.
You have the step log in /tmp/logfile to identify the root cause of the installation failure.
Look for ansible task failures, network connectivity issues, node provisioning errors,
or OpenShift installer errors. You should connect to installer host if it exists as root@$<IP>
and run there 'oc' commands and IP you can see by running: kcli show vm ${CLUSTER_NAME}-installer .
The main log in this host is in /var/log/cloud-init-output.log and it desribes the whole preparation
and cluster installation. Scripts that run in this log are in /root/scripts of installer host.
**Important! the log may contain red herrings, not every
error there is true issue, you need to run oc commands to make sure it's an issue**.
Make sure you identify the real root cause and not judging just by looking at errors in logs!
Start from running basic oc commands to discover a status of the cluster.
You can connect to any node in cluster with user 'core' and IP you can see running 'kcli list vm',
your nodes have ${CLUSTER_NAME} in their name. Provide a summary of what went wrong and suggest fixes."

elif [[ "$DIAGNOSE_BASENAME" == "diagnose-telco5g-sno-setup.early" ]]; then
    PROMPT_BODY="The Single Node OpenShift (SNO) baremetal cluster installation failed early.
The SNO cluster was being installed using GitOps and ansible playbooks on a single baremetal node.
Analyze the setup log below to identify the root cause of the installation failure.
Look for initialization errors, environment setup failures, ansible task failures,
node provisioning errors, bootstrap issues, or OpenShift installer errors.
Provide a summary of what went wrong and suggest fixes."

elif [[ "$DIAGNOSE_BASENAME" == "diagnose-telco5g-sno-setup" ]]; then
    PROMPT_BODY="The Single Node OpenShift (SNO) baremetal cluster installation failed.
Cluster: ${CLUSTER_NAME:-unknown}
The SNO cluster was being installed using kcli and ansible playbooks on a single baremetal node.
Analyze the setup log below to identify the root cause of the installation failure.
Look for ansible task failures, node provisioning errors, bootstrap issues,
or OpenShift installer errors specific to SNO deployments. Provide a summary of what went wrong and suggest fixes."

elif [[ "$DIAGNOSE_BASENAME" == "diagnose-telco5g-hcp-cluster-setup.early" ]]; then
    PROMPT_BODY="The Hosted Control Planes (HCP) cluster setup failed early.
The HCP management and guest clusters were being provisioned using ansible playbooks on baremetal nodes.
Analyze the setup log below to identify the root cause of the failure.
Look for initialization errors, environment setup failures, ansible task failures,
HCP-specific provisioning errors, or network/node problems.
Provide a summary of what went wrong and suggest fixes."

elif [[ "$DIAGNOSE_BASENAME" == "diagnose-telco5g-hcp-cluster-setup" ]]; then
    PROMPT_BODY="The Hosted Control Planes (HCP) cluster setup failed.
Cluster: ${CLUSTER_NAME:-unknown}, SNO: ${SNO_NAME:-unknown}, Management version: ${MGMT_VERSION:-unknown}
The HCP management and guest clusters were being provisioned using ansible playbooks on baremetal nodes.
Analyze the setup log below to identify the root cause of the failure.
My Host cluster is called sno-${CLUSTER_NAME} and it is Single Node Openshift (SNO) on virtual machine
on hypervisor and runs ACM (Advanced Cluster Management) which installs Guest HCP clusters.
Kubeconfig of host cluster is in ~/hcp-jobs/sno-${CLUSTER_NAME}/config/auth/kubeconfig ,
use ~/bin/oc client to query hub cluster about failures. If SNO hub is not installed or API doesn't work,
ssh to it with 'core' user as 'ssh core@<IP>' and investigate. IP you can see by running
kcli show vm sno-${CLUSTER_NAME} .
Make sure you identify the real root cause and not judging just by looking at errors in logs!
Look for ansible task failures in step log, HCP-specific provisioning errors,
hosted cluster creation issues, or network/node problems. Log of step is in /tmp/logfile if it exists
and if not - start from checking if hub cluster exists, if it does - query it for errors
of guest installations. Provide a summary of what went wrong and suggest fixes."

elif [[ "$DIAGNOSE_BASENAME" == "diagnose-telco5g-sno-ztp-cluster-setup.early" ]]; then
    PROMPT_BODY="The Single Node OpenShift (SNO) via ZTP/GitOps cluster provisioning failed early.
The SNO cluster was being provisioned using Zero Touch Provisioning with ACM/GitOps on baremetal.
Analyze the setup log below to identify the root cause of the failure.
Look for initialization errors, environment setup failures, ansible task failures,
ZTP provisioning errors, or ACM hub cluster issues.
Hub kubeconfig is in ~/ztp-jobs/sno-${CLUSTER_NAME}/config/auth/kubeconfig, run binary ~/bin/oc
with this kubeconfig to query the Hub OCP. Spoke files are in ~/ztp-jobs/sno-${CLUSTER_NAME}/ztphub-${CLUSTER_NAME}/out
and it might have kubeconfig in ~/ztp-jobs/sno-${CLUSTER_NAME}/ztphub-${CLUSTER_NAME}/out/${CLUSTER_NAME}-kubeconfig
if it reached this installation step. Provide a summary of what went wrong and suggest fixes."

elif [[ "$DIAGNOSE_BASENAME" == "diagnose-telco5g-sno-ztp-cluster-setup" ]]; then
    PROMPT_BODY="The Single Node OpenShift (SNO) via ZTP/GitOps cluster provisioning failed.
Cluster: ${CLUSTER_NAME:-unknown}, SNO: ${SNO_NAME:-unknown}, Management version: ${MGMT_VERSION:-unknown}
My hub is called sno-${CLUSTER_NAME} and it is Single Node Openshift (SNO) on virtual machine on hypervisor and runs
ACM (Advanced Cluster Management). It installs Spoke cluster - SNO on baremetal host
To know hub IP run command kcli show vm sno-${CLUSTER_NAME} and you can connect with 'core' user to it as
'ssh core@<IP>'. Hub kubeconfig is in ~/ztp-jobs/sno-${CLUSTER_NAME}/config/auth/kubeconfig,
run binary ~/bin/oc with this kubeconfig to query the Hub OCP. If SNO hub is not installed or API doesn't work,
ssh to it with 'core' user as 'ssh core@<IP>' and investigate. IP you can see by running
kcli show vm sno-${CLUSTER_NAME} .
Spoke is baremetal SNO cluster, its files are in ~/ztp-jobs/sno-${CLUSTER_NAME}/ztphub-${CLUSTER_NAME}/out
and it might have kubeconfig in ~/ztp-jobs/sno-${CLUSTER_NAME}/ztphub-${CLUSTER_NAME}/out/${CLUSTER_NAME}-kubeconfig
if it reached this installation step.
Analyze the setup log below to identify the root cause of the failure os spoke or hub cluster.
Look for ansible task failures, ZTP provisioning errors, ACM hub cluster issues,
spoke cluster deployment problems. Log of step is in /tmp/logfile if it exists. If not - start from
analyzing hub cluster and its spoke clusters with 'oc' client.
Provide a summary of what went wrong and suggest fixes."

elif [[ "$DIAGNOSE_BASENAME" == "diagnose-telco5g-mno-ztp-cluster-setup.early" ]]; then
    PROMPT_BODY="The Multi-Node OpenShift (MNO) via ZTP/GitOps cluster provisioning failed early.
The MNO cluster was being provisioned using Zero Touch Provisioning with ACM/GitOps on baremetal.
Analyze the setup log below to identify the root cause of the failure.
Look for initialization errors, environment setup failures, ansible task failures,
ZTP provisioning errors, or ACM hub cluster issues.
Provide a summary of what went wrong and suggest fixes."

elif [[ "$DIAGNOSE_BASENAME" == "diagnose-telco5g-mno-ztp-cluster-setup" ]]; then
    PROMPT_BODY="The Multi Node OpenShift (MNO) via ZTP/GitOps cluster provisioning failed.
Cluster: ${CLUSTER_NAME:-unknown}, SNO: ${SNO_NAME:-unknown}, Management (hub) version: ${MGMT_VERSION:-unknown}
My hub is called sno-${CLUSTER_NAME} and it is Single Node Openshift (SNO) on virtual machine on hypervisor and runs
ACM (Advanced Cluster Management) and its kubeconfig is in ~/ztp-jobs/sno-${CLUSTER_NAME}/config/auth/kubeconfig,
run binary ~/bin/oc with this kubeconfig to query the Hub OCP. If SNO hub is not installed or API doesn't work,
ssh to it with 'core' user as 'ssh core@<IP>' and investigate. IP you can see by running
kcli show vm sno-${CLUSTER_NAME} .Spoke cluster is MNO (Multinode) Openshift cluster with baremetal workers.
Spoke files are in ~/ztp-jobs/sno-${CLUSTER_NAME}/ztphub-${CLUSTER_NAME}/out
and it might have kubeconfig in ~/ztp-jobs/sno-${CLUSTER_NAME}/ztphub-${CLUSTER_NAME}/out/${CLUSTER_NAME}-kubeconfig
if it reached this installation step.
The MNO cluster was being provisioned using Zero Touch Provisioning with ACM/GitOps.
Analyze the setup log below to identify the root cause of the failure os spoke or hub cluster.
Look for ansible task failures, ZTP provisioning errors, ACM hub cluster issues,
spoke cluster deployment problems. Log of step is in /tmp/logfile if it exists. If not - start from
analyzing hub cluster and its spoke clusters with 'oc' client.
Provide a summary of what went wrong and suggest fixes."

elif [[ "$DIAGNOSE_BASENAME" == "diagnose-telco5g-cnf-tests.early" ]]; then
    PROMPT_BODY="The CNF features-deploy e2e tests failed early on a telco5g baremetal cluster.
These tests validate CNF-specific features like SRIOV, DPDK, SCTP, performance profiles, etc.
Analyze the test log below to identify the root cause of the early failure.
Look for initialization errors, environment setup failures, cluster state issues,
or operator problems. Log of step is in /tmp/logfile.
Provide a summary of what went wrong and suggest fixes."

elif [[ "$DIAGNOSE_BASENAME" == "diagnose-telco5g-cnf-tests" ]]; then
    PROMPT_BODY="The CNF features-deploy e2e tests failed on a telco5g baremetal cluster.
Branch: ${CNF_BRANCH:-unknown}, Features: ${TEST_RUN_FEATURES:-unknown}
These tests validate CNF-specific features like SRIOV, DPDK, SCTP, performance profiles, etc.
Analyze the test log below to identify which tests failed and why.
Look for test assertion failures, cluster state issues, operator problems,
or infrastructure errors that caused test failures. Log of step is in /tmp/logfile.
Run ~/bin/oc openshift client to query the cluster and use kubeconfig in /tmp/kubeconfig .
Report if you can not run 'oc get node' for example. Look into pod logs and see what is wrong.
You can find source of tests in:
for PAO (performance operator) - https://github.com/openshift/cluster-node-tuning-operator
for metallb - https://github.com/openshift/metallb-operator
and for SRIOV - https://github.com/openshift/sriov-network-operator
You can check in step log which exactly commits are set. The whole test suite is running
with https://github.com/openshift-kni/cnf-features-deploy repo.
Provide a summary of failures and suggest fixes."

elif [[ "$DIAGNOSE_BASENAME" == "diagnose-telco5g-sriov-tests.early" ]]; then
    PROMPT_BODY="The SRIOV operator e2e tests failed early on a telco5g baremetal cluster.
These tests validate SR-IOV network operator functionality including VF creation,
network attachment definitions, and DPDK workloads.
Analyze the test log below to identify the root cause of the early failure.
Look for initialization errors, environment setup failures, SRIOV operator errors,
or cluster state problems. Provide a summary of what went wrong and suggest fixes."

elif [[ "$DIAGNOSE_BASENAME" == "diagnose-telco5g-sriov-tests" ]]; then
    PROMPT_BODY="The SRIOV operator e2e tests failed on a telco5g baremetal cluster.
SRIOV branch: ${SRIOV_BRANCH:-unknown}
These tests validate SR-IOV network operator functionality including VF creation,
network attachment definitions, and DPDK workloads.
Analyze the test log below to identify which tests failed and why.
Look for SRIOV operator errors, VF allocation failures, network configuration issues,
or cluster state problems. Provide a summary of failures and suggest fixes."

elif [[ "$DIAGNOSE_BASENAME" == "diagnose-telco5g-origin-tests.early" ]]; then
    PROMPT_BODY="The OpenShift origin conformance tests failed early on a telco5g baremetal cluster.
These tests run the openshift-tests conformance suite to validate cluster functionality.
Analyze the test log below to identify the root cause of the early failure.
Look for initialization errors, environment setup failures, cluster instability,
or operator degradation. Provide a summary of what went wrong and suggest fixes."

elif [[ "$DIAGNOSE_BASENAME" == "diagnose-telco5g-origin-tests" ]]; then
    PROMPT_BODY="The OpenShift origin conformance tests failed on a telco5g baremetal cluster.
Cluster: ${CLUSTER_NAME:-unknown}, Test suite: ${TEST_SUITE:-unknown}
These tests run the openshift-tests conformance suite to validate cluster functionality.
Analyze the test log below to identify which tests failed and why.
Look for test assertion failures, cluster instability, operator degradation,
or infrastructure issues. Provide a summary of failures and suggest fixes."

else
    PROMPT_BODY="The telco5g CI job step ${STEP_NAME} failed.
Analyze the log below to identify the root cause of the failure.
Provide a summary of what went wrong and suggest fixes."
fi

PROMPT="${PROMPT_HEADER}

${PROMPT_BODY}

Write what you detected, which actions made, what discovered and what are conclusions.
Report must be as HTML file, not Markdown. Write it to /tmp/job-report.html with HTML title 'AI investigation'
Make sure you set background color explicitly, not transparent,
since its background can be both white and dark grey.
## Jira check - use acli tool for this
Check in Jira epic CNF-24140 in **opened stories only** if there is already stories for issues you
discovered here. It shouldn't be exactly same, but similar.
If there are no similar issues - open a new issue in epic CNF-24140 with details from report.
Put here also link to job artifacts: $JOB_URL
** IMPORTANT ** If similar issue exists in epic CNF-24140, do NOT do an investigation,
just add a comment with job url $JOB_URL to relevant issue and exit. HTML page should contain
the link to the issue in Jira and short message about issue already tracked in Jira.
"

echo "Failed step prompt:"
echo "${PROMPT}"
echo "Log file: ${LOG_FILE:-none}"

# Check if we can run remote diagnostics
if [[ ! -f "${SHARED_DIR}/inventory" ]]; then
    echo "No inventory file found. Cannot run remote diagnostics (setup failed before creating inventory)."
    exit 0
fi

# Write prompt to a local file to avoid YAML escaping issues
echo "${PROMPT}" > /tmp/diagnose-prompt.txt

# Generate Ansible playbook to run AI agent on the hypervisor
cat << 'PLAYBOOKEOF' > ~/run-diagnose.yml
---
- name: Run AI diagnostics on hypervisor
  hosts: hypervisor
  gather_facts: false
  tasks:

  - name: Wait for connection
    wait_for_connection:
      delay: 5
      timeout: 120

  - name: Copy log file to hypervisor
    copy:
      src: "{{ log_file }}"
      dest: /tmp/diagnose-log-{{ log_prefix }}.log
      mode: '0644'
    ignore_errors: true

  - name: Copy prompt to hypervisor
    copy:
      src: "{{ prompt_file }}"
      dest: /tmp/diagnose-prompt-{{ log_prefix }}.txt
      mode: '0644'

  - name: Copy kubeconfig to hypervisor if exists
    copy:
      src: "{{ kubeconfig_file }}"
      dest: /tmp/diagnose-kubeconfig-{{ log_prefix }}.txt
      mode: '0644'
    ignore_errors: true

  - name: Run AI diagnose agent
    shell: >-
      ~/run-diagnose.sh
      --prompt /tmp/diagnose-prompt-{{ log_prefix }}.txt
      --log /tmp/diagnose-log-{{ log_prefix }}.log
      --kubeconfig /tmp/diagnose-kubeconfig-{{ log_prefix }}.txt
      --output /tmp/diagnose-output-{{ log_prefix }}.txt
      --html-report {{ html_report }}
    async: 1500
    poll: 0
    register: diagnose_job
    ignore_errors: true

  - name: Wait for diagnose agent to complete
    async_status:
      jid: "{{ diagnose_job.ansible_job_id }}"
    register: job_result
    until: job_result.finished
    retries: 25
    delay: 60
    ignore_errors: true

  - name: Fetch diagnose output
    fetch:
      src: /tmp/diagnose-output-{{ log_prefix }}.txt
      dest: "{{ artifact_dir }}/diagnose-output.txt"
      flat: yes
    ignore_errors: true

  - name: Fetch HTML report
    fetch:
      src: "{{ html_report }}"
      dest: "{{ artifact_dir }}/job-report.html"
      flat: yes
    ignore_errors: true

  - name: Clean up remote files
    file:
      path: "{{ item }}"
      state: absent
    loop:
      - /tmp/diagnose-log-{{ log_prefix }}.log
      - /tmp/diagnose-prompt-{{ log_prefix }}.txt
      - /tmp/diagnose-output-{{ log_prefix }}.txt
      - /tmp/diagnose-kubeconfig-{{ log_prefix }}.txt
    ignore_errors: true

PLAYBOOKEOF

echo "Running remote AI diagnostics on hypervisor..."
ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook \
    -i "$SHARED_DIR/inventory" \
    ~/run-diagnose.yml \
    -e "log_file=${LOG_FILE}" \
    -e "prompt_file=/tmp/diagnose-prompt.txt" \
    -e "artifact_dir=${ARTIFACT_DIR}" \
    -e "log_prefix=${LOG_PREFIX}" \
    -e "kubeconfig_file=${SHARED_DIR}/kubeconfig.original" \
    -e "html_report=/tmp/diagnose-report-${LOG_PREFIX}.html" \
    -vv || true

if [[ -f "${ARTIFACT_DIR}/diagnose-output.txt" ]]; then
    cat "${ARTIFACT_DIR}/diagnose-output.txt"
    cp "${ARTIFACT_DIR}/job-report.html" "$ARTIFACT_DIR/test-summary.html" || true
else
    echo "No diagnose output received from the hypervisor."
fi
cp "${SHARED_DIR}/kubeconfig.original" "${ARTIFACT_DIR}/" || true
cp "${LOG_FILE}" "${ARTIFACT_DIR}/" || true
cp /tmp/diagnose-prompt.txt ${ARTIFACT_DIR}/ || true
