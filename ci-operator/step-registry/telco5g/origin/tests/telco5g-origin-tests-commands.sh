#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# shellcheck disable=SC1091
source "$SHARED_DIR/main.env"

export FEATURES="${FEATURES:-sriov performance sctp xt_u32 ovn metallb multinetworkpolicy}" # next: ovs_qos
export CNF_REPO="${CNF_REPO:-https://github.com/openshift-kni/cnf-features-deploy.git}"
export CNF_BRANCH="${CNF_BRANCH:-master}"

# Ref.: https://github.com/openshift/release/blob/master/ci-operator/step-registry/baremetalds/e2e/test/baremetalds-e2e-test-commands.sh
export TEST_PROVIDER='{"type":"baremetal"}'

echo "************ telco5g origin tests commands ************"
# Fix user IDs in a container
[ -e "$HOME/fix_uid.sh" ] && "$HOME/fix_uid.sh" || echo "$HOME/fix_uid.sh was not found" >&2

SSH_PKEY_PATH=/var/run/ci-key/cikey
SSH_PKEY=~/key
cp "$SSH_PKEY_PATH" "$SSH_PKEY"
chmod 600 "$SSH_PKEY"

if [[ "$T5CI_VERSION" == "4.15" ]]; then
    export CNF_BRANCH="master"
else
    export CNF_BRANCH="release-${T5CI_VERSION}"
fi

cnf_dir=$(mktemp -d -t cnf-XXXXX)
cd "$cnf_dir" || exit 1

echo "running on branch ${CNF_BRANCH}"
git clone -b "${CNF_BRANCH}" "${CNF_REPO}" cnf-features-deploy
cd cnf-features-deploy
if [[ "$T5CI_VERSION" == "4.15" ]]; then
    echo "Updating all submodules for >=4.15 versions"
    # git version 1.8 doesn't work well with forked repositories, requires a specific branch to be set
    sed -i "s@https://github.com/openshift/metallb-operator.git@https://github.com/openshift/metallb-operator.git\n        branch = main@" .gitmodules
    git submodule update --init --force --recursive --remote
    git submodule foreach --recursive 'echo $path `git config --get remote.origin.url` `git rev-parse HEAD`' | grep -v Entering > ${ARTIFACT_DIR}/hashes.txt || true
fi
oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'

FEATURES_ENVIRONMENT="ci" make feature-deploy-on-ci 2>&1 | tee "${SHARED_DIR}/cnf-tests-run.log"

cd

# Wait until number of nodes matches number of machines
# Ref.: https://github.com/openshift/release/blob/master/ci-operator/step-registry/openshift/e2e/test/openshift-e2e-test-commands.sh
for i in $(seq 30); do
    nodes="$(oc get nodes --no-headers | wc -l)"
    machines="$(oc get machines -A --no-headers | wc -l)"
    [ "$machines" -le "$nodes" ] && break
    sleep 30
done

[ "$machines" -le "$nodes" ]

# Wait for nodes to be ready
# Ref.: https://github.com/openshift/release/blob/master/ci-operator/step-registry/openshift/e2e/test/openshift-e2e-test-commands.sh
oc wait nodes --all --for=condition=Ready=true --timeout=10m

# Waiting for clusteroperators to finish progressing
# Ref.: https://github.com/openshift/release/blob/master/ci-operator/step-registry/openshift/e2e/test/openshift-e2e-test-commands.sh
oc wait clusteroperators --all --for=condition=Progressing=false --timeout=10m

# Pull secrets might be required to extract url to container image of OpenShift's conformance test suite
oc get secret pull-secret -n openshift-config -o jsonpath="{.data['\.dockerconfigjson']}" \
    | base64 --decode > pull-secret.txt

# Pull secrets are required to pull container image for openshift-tests
oc get secret pull-secret -n openshift-config -o yaml | grep -v '^\s*namespace:\s' | oc apply -f -

# Extract url to container image of OpenShift's conformance test suite aka openshift-tests
T5_JOB_TESTS_IMAGE=$(oc adm release info --registry-config pull-secret.txt --image-for=tests "$T5_JOB_RELEASE_IMAGE")

# Launch a pod from the openshift-tests image and let it idle
# while we copy the openshift-tests binary out of the container
oc run telco5g-tests-extractor --restart=Never --image "$T5_JOB_TESTS_IMAGE" --command=true \
    --overrides='{ "spec": { "template": { "spec": { "imagePullSecrets": [{"name": "pull-secret"}] } } } }' \
    -- sleep 3600

oc wait pod/telco5g-tests-extractor --for=condition=Ready --timeout=15m

# Extract openshift-tests binary from container
# shellcheck disable=SC2034
for i in $(seq 10); do # retry because copy is flaky
    if oc cp telco5g-tests-extractor:/usr/bin/openshift-tests openshift-tests; then
        break
    else
        rm -f openshift-tests # remove incompletely transferred files
        sleep 5
    fi
done
[ -e "openshift-tests" ]

oc delete pods telco5g-tests-extractor

chmod a+x openshift-tests

# Determine list of tests
./openshift-tests run --dry-run --provider "${TEST_PROVIDER}" "${TEST_SUITE}" > "$ARTIFACT_DIR/tests-all.txt"
if [ -n "${TEST_SKIPS}" ]; then
    grep -v "$TEST_SKIPS" "$ARTIFACT_DIR/tests-all.txt" > "$ARTIFACT_DIR/tests-run.txt"

    if ! grep "$TEST_SKIPS" "$ARTIFACT_DIR/tests-all.txt" > "$ARTIFACT_DIR/tests-skip.txt"; then
      echo >&2 "ERROR: No tests were found matching the TEST_SKIPS regex:"
      echo >&2 "$TEST_SKIPS"
      exit 1
    fi

    TEST_FILE=tests-run.txt
else
    TEST_FILE=tests-all.txt
fi

IFS=- read -r CLUSTER_NAME _ <<< "$(cat "${SHARED_DIR}/cluster_name")"

cat << EOF > run-openshift-tests.yml
---
- name: Run OpenShift's conformance test suite
  hosts: hypervisor
  gather_facts: false
  any_errors_fatal: true

  tasks:
  - name: Copy OpenShift's conformance test suite through hypervisor to installer, run it and retrieve results
    block:
    - name: Create script on hypervisor to run openshift-tests binary on installer
      ansible.builtin.copy:
        content: |
          #!/bin/bash

          set -o nounset
          set -o errexit
          set -o pipefail

          export KUBECONFIG=/root/ocp/auth/kubeconfig

          openshift-tests run "${TEST_SUITE}" \\
            --provider '${TEST_PROVIDER}' \\
            -o e2e.log --junit-dir junit --file /root/tests.txt \\
            > openshift-tests.log
        dest: '/tmp/kcli_${CLUSTER_NAME}_run-openshift-tests.sh'
        mode: 0755

    - name: Copy script from hypervisor to artifacts directory
      ansible.builtin.fetch:
        src: '/tmp/kcli_${CLUSTER_NAME}_run-openshift-tests.sh'
        dest: '${ARTIFACT_DIR}/run-openshift-tests.sh'
        flat: true

    - name: Copy openshift-tests binary to hypervisor
      ansible.builtin.copy:
        src: '${PWD}/openshift-tests'
        dest: '/tmp/kcli_${CLUSTER_NAME}_openshift-tests'

    - name: Copy list of tests to hypervisor
      ansible.builtin.copy:
        src: '${ARTIFACT_DIR}/${TEST_FILE}'
        dest: '/tmp/kcli_${CLUSTER_NAME}_${TEST_FILE}'

    - name: Copy script to run openshift-tests binary to installer
      ansible.builtin.shell:
        cmd: |
          kcli scp '/tmp/kcli_${CLUSTER_NAME}_run-openshift-tests.sh' \\
            'root@${CLUSTER_NAME}-installer:/usr/local/bin/run-openshift-tests.sh' \\
          && kcli ssh 'root@${CLUSTER_NAME}-installer' 'chmod a+x /usr/local/bin/run-openshift-tests.sh'

    - name: Copy openshift-tests binary to installer
      ansible.builtin.shell:
        cmd: |
          kcli scp '/tmp/kcli_${CLUSTER_NAME}_openshift-tests' \\
            'root@${CLUSTER_NAME}-installer:/usr/local/bin/openshift-tests' \\
          && kcli ssh 'root@${CLUSTER_NAME}-installer' 'chmod a+x /usr/local/bin/openshift-tests'

    - name: Copy list of tests to installer
      ansible.builtin.shell:
        cmd: |
          kcli scp '/tmp/kcli_${CLUSTER_NAME}_${TEST_FILE}' \\
            'root@${CLUSTER_NAME}-installer:/root/tests.txt' \\

    - name: Test kubeconfig on installer
      ansible.builtin.shell:
        cmd: |
          kcli ssh 'root@${CLUSTER_NAME}-installer' "sh -c 'export KUBECONFIG=/root/ocp/auth/kubeconfig && oc get nodes'"

    - name: Run script for openshift-tests binary on installer
      ansible.builtin.shell:
        cmd: |
          kcli ssh 'root@${CLUSTER_NAME}-installer' "run-openshift-tests.sh || true"

    - name: Compress results from openshift-tests binary on installer
      ansible.builtin.shell:
        cmd: |
          kcli ssh 'root@${CLUSTER_NAME}-installer' \\
            "tar -czf openshift-tests.tar.gz e2e.log junit/ openshift-tests.log || { rm -f openshift-tests.tar.gz; exit 1; }"

    - name: Copy results from installer to hypervisor
      ansible.builtin.shell:
        cmd: |
          kcli scp 'root@${CLUSTER_NAME}-installer:/root/openshift-tests.tar.gz' \\
            '/tmp/kcli_${CLUSTER_NAME}_openshift-tests.tar.gz'

    - name: Copy results from hypervisor to artifacts directory
      ansible.builtin.fetch:
        src: '/tmp/kcli_${CLUSTER_NAME}_openshift-tests.tar.gz'
        dest: '${ARTIFACT_DIR}/openshift-tests.tar.gz'
        flat: true

    always:
    - name: Remove script to run openshift-tests binary from hypervisor
      ansible.builtin.file:
        path: '/tmp/kcli_${CLUSTER_NAME}_run-openshift-tests.sh'
        state: absent
      ignore_errors: true

    - name: Remove openshift-tests binary from hypervisor
      ansible.builtin.file:
        path: '/tmp/kcli_${CLUSTER_NAME}_openshift-tests'
        state: absent
      ignore_errors: true

    - name: Remove list of tests from hypervisor
      ansible.builtin.file:
        path: '/tmp/kcli_${CLUSTER_NAME}_${TEST_FILE}'
        state: absent
      ignore_errors: true

    - name: Remove openshift-tests results from hypervisor
      ansible.builtin.file:
        path: '/tmp/kcli_${CLUSTER_NAME}_openshift-tests.tar.gz'
        state: absent
      ignore_errors: true
EOF

# Run OpenShift's conformance test suite
ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -i "$SHARED_DIR/inventory" run-openshift-tests.yml -vv

cd "$ARTIFACT_DIR"
tar -xf openshift-tests.tar.gz
rm openshift-tests.tar.gz

cd junit/
for f in test-failures-summary_*.json; do
    if [ -e "$f" ]; then
        ln -s "$f" test-failures-summary.json
        break
    fi
done
