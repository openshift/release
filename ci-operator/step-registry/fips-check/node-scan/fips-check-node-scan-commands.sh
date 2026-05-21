#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

# --- TLS Scanner (parallel) ---------------------------------------------------
# Launch the TLS scanner early so it runs in parallel with the FIPS node scan.
# The scanner image is provided by the PULL_SPEC_TLS_SCANNER_TOOL dependency.
# Its exit code is intentionally ignored — it produces informational artifacts only.

TLS_SCANNER_NS="tls-scanner"
TLS_SCANNER_IMAGE="${PULL_SPEC_TLS_SCANNER_TOOL:-}"
TLS_SCANNER_ARTIFACT_DIR="${ARTIFACT_DIR}/tls-scanner"
TLS_SCANNER_STARTED=false

function start_tls_scanner() {
    if [[ -z "${TLS_SCANNER_IMAGE}" ]]; then
        echo "[tls-scanner] PULL_SPEC_TLS_SCANNER_TOOL not set — skipping TLS scan."
        return
    fi

    echo "=== Starting TLS Scanner (parallel) ==="
    echo "[tls-scanner] Image: ${TLS_SCANNER_IMAGE}"
    mkdir -p "${TLS_SCANNER_ARTIFACT_DIR}"

    # Create namespace
    oc create namespace "${TLS_SCANNER_NS}" --dry-run=client -o yaml | oc apply -f -

    # Grant cluster-admin and privileged SCC
    oc adm policy add-cluster-role-to-user cluster-admin -z default -n "${TLS_SCANNER_NS}"
    oc adm policy add-scc-to-user privileged -z default -n "${TLS_SCANNER_NS}"

    # Wait for RBAC/SCC changes to propagate
    sleep 10

    # Deploy the scanner pod
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: tls-scanner
  namespace: ${TLS_SCANNER_NS}
spec:
  serviceAccountName: default
  restartPolicy: Never
  hostNetwork: true
  hostPID: true
  containers:
  - name: scanner
    image: ${TLS_SCANNER_IMAGE}
    command:
    - /bin/bash
    - -c
    - |
      mkdir -p /results
      /usr/local/bin/tls-scanner -j 4 --all-pods \
        --json-file /results/results.json \
        --csv-file /results/results.csv \
        --junit-file /results/junit_tls_scan.xml \
        --log-file /results/scan.log 2>&1 | tee /results/output.log
      SCAN_EXIT_CODE=\${PIPESTATUS[0]}
      echo "Scan complete. Exit code: \${SCAN_EXIT_CODE}" | tee -a /results/output.log
      touch /results/scan.done
      # Keep pod alive for artifact collection
      sleep 120
    resources:
      requests:
        cpu: "4"
        memory: 4Gi
      limits:
        cpu: "4"
        memory: 4Gi
    securityContext:
      privileged: true
      runAsUser: 0
    volumeMounts:
    - name: results
      mountPath: /results
  volumes:
  - name: results
    emptyDir: {}
EOF

    echo "[tls-scanner] Waiting for scanner pod to start..."
    if oc wait --for=condition=Ready pod/tls-scanner -n "${TLS_SCANNER_NS}" --timeout=5m; then
        TLS_SCANNER_STARTED=true
        echo "[tls-scanner] Pod is running — scan will proceed in parallel."
    else
        echo "[tls-scanner] WARNING: Pod failed to start. Continuing without TLS scan."
        oc describe pod/tls-scanner -n "${TLS_SCANNER_NS}" || true
    fi
}

function collect_tls_scanner_results() {
    if [[ "${TLS_SCANNER_STARTED}" != "true" ]]; then
        return
    fi

    echo "=== Collecting TLS Scanner Results ==="

    # Wait for scan.done marker or pod exit
    local max_wait=14400  # 4 hours
    local elapsed=0
    while (( elapsed < max_wait )); do
        if oc exec pod/tls-scanner -n "${TLS_SCANNER_NS}" -- test -f /results/scan.done 2>/dev/null; then
            echo "[tls-scanner] scan.done found — collecting artifacts"
            break
        fi
        local phase
        phase=$(oc get pod/tls-scanner -n "${TLS_SCANNER_NS}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]]; then
            echo "[tls-scanner] Pod ${phase} — attempting artifact collection"
            break
        fi
        sleep 15
        elapsed=$((elapsed + 15))
    done

    # Copy artifacts
    oc cp "${TLS_SCANNER_NS}/tls-scanner:/results/." "${TLS_SCANNER_ARTIFACT_DIR}/" || echo "[tls-scanner] WARNING: Failed to copy some artifacts"

    if [[ -f "${TLS_SCANNER_ARTIFACT_DIR}/junit_tls_scan.xml" ]]; then
        cp "${TLS_SCANNER_ARTIFACT_DIR}/junit_tls_scan.xml" "${ARTIFACT_DIR}/junit_tls_scan.xml"
        echo "[tls-scanner] JUnit results copied to ${ARTIFACT_DIR}/junit_tls_scan.xml"
    fi

    echo "[tls-scanner] Artifacts saved to: ${TLS_SCANNER_ARTIFACT_DIR}"
    ls -la "${TLS_SCANNER_ARTIFACT_DIR}" || true

    # Cleanup
    oc delete namespace "${TLS_SCANNER_NS}" --ignore-not-found --wait=false || true
    echo "=== TLS Scanner Complete ==="
}

# --- Main: start TLS scanner, then run FIPS node scan -------------------------

set_proxy
run_command "oc whoami"
run_command "oc version -o yaml"

# Launch TLS scanner in the background (non-blocking)
start_tls_scanner

pass=true

# skip for ARM64
mapfile -t node_archs< <(oc get nodes -o jsonpath --template '{range .items[*]}{.status.nodeInfo.architecture}{"\n"}{end}' | sort -R | uniq -d)
echo "The architectures included in the current cluster nodes are ${node_archs[*]}"
NON_SUPPORTED_ARCHES=(arm64)
for arch in "${node_archs[@]}"; do
    if [[ "${NON_SUPPORTED_ARCHES[*]}" =~ $arch ]]; then
        echo "Skip this test since it doesn't support $arch."
        collect_tls_scanner_results
        exit 0
    fi
done

# get a master node
master_node_0=$(oc get node -l node-role.kubernetes.io/master= --no-headers | grep -Ev "NotReady|SchedulingDisabled"| awk '{print $1}' | awk 'NR==1{print}')
if [[ -z $master_node_0 ]]; then
    echo "Error master node0 name is null!"
    pass=false
fi
# create a ns
project="node-scan-$RANDOM"
run_command "oc new-project $project --skip-config-write"
if [ $? == 0 ]; then
    echo "create $project project successfully" 
else
    echo "Fail to create $project project."
    pass=false
fi
# check whether it is disconnected cluster
run_command "oc extract secret/pull-secret -n openshift-config --confirm --to /tmp"; ret=$?
if [[ $ret -eq 0 ]]; then
    auths=`cat /tmp/.dockerconfigjson`
    if [[ $auths =~ "5000" ]]; then
        echo "This is a disconnected env, skip it."
        collect_tls_scanner_results
        exit 0
    fi
fi

# run node scan and check the result
report="/tmp/fips-check-node-scan.log"
oc label namespace "$project" security.openshift.io/scc.podSecurityLabelSync=false pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite=true || true
cluster_http_proxy=$(oc get proxy cluster -o=jsonpath='{.spec.httpProxy}')
cluster_https_proxy=$(oc get proxy cluster -o=jsonpath='{.spec.httpProxy}')
oc --request-timeout=300s -n "$project" debug node/"$master_node_0" -- chroot /host bash -c "export http_proxy=$cluster_http_proxy; export https_proxy=$cluster_https_proxy; podman run --authfile /var/lib/kubelet/config.json --privileged -i -v /:/myroot registry.ci.openshift.org/ci/check-payload:latest scan node --root  /myroot &> $report" || true
out=$(oc --request-timeout=300s -n "$project" debug node/"$master_node_0" -- chroot /host bash -c "cat /$report" || true)
echo "The report is: $out"
oc delete ns $project || true
res=$(echo "$out" | grep -E 'Failure Report|Successful run with warnings|Warning Report' || true)
if [[ -n $res ]];then
    echo "The result is: $res"
    pass=false
fi

# --- Collect TLS scanner results (waits for completion) -----------------------
collect_tls_scanner_results

# generate report
echo "Generating the Junit for fips check node scan"
filename="junit_fips-check-node-scan"
testsuite="fips-check-node-scan"
subteam="Security_and_Compliance"
if $pass; then
    cat >"${ARTIFACT_DIR}/${filename}.xml" <<EOF
    <testsuite name="${testsuite}" failures="0" errors="0" skipped="0" tests="1" time="$SECONDS">
        <testcase name="${subteam}:Node scan of fips check should succeedded or skipped"/>
    </testsuite>
EOF
else
    cat >"${ARTIFACT_DIR}/${filename}.xml" <<EOF
    <testsuite name="${testsuite}" failures="1" errors="0" skipped="0" tests="1" time="$SECONDS">
        <testcase name="${subteam}:Node scan of fips check should succeedded or skipped">
            <failure message="">
                Node scan failed due to errors or warnings:
                <![CDATA[$res]]>
            </failure>
        </testcase>
    </testsuite>
EOF
fi
