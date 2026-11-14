#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# Restrictive default permissions: the credential file this step writes is
# owner-only.
umask 077

# shellcheck disable=SC2317
_propagate_junit () {
    [[ -n "${SHARED_DIR:-}" ]] || return 0
    mkdir -p "${SHARED_DIR}/junit"
    # Error suppression justified: _propagate_junit is best-effort cleanup on EXIT trap.
    # If no XML files exist or ARTIFACT_DIR is unset, we want the trap to succeed (not fail the entire test).
    find "${ARTIFACT_DIR:-}" -name '*.xml' -exec cp {} "${SHARED_DIR}/junit/" \; || true
}

# Suite naming for the JUnit post-processing library: compose its suite-name
# template from the component-suffixed prefix variable the consuming job sets.
# The step ref declares the prefix with no default on purpose, so a step-local
# value can never pin a prefix the job cannot see. When the prefix is unset
# the raw suite name is kept, so the step still reports, and the gap is called
# out loudly instead of failing the run.
if [[ -n "${LP_QE__CR__TS_NAME__PFX__ACM:-}" ]]; then
    export LP_IO__ET_PPP__NEW_TS_NAME="${LP_QE__CR__TS_NAME__PFX__ACM:+${LP_QE__CR__TS_NAME__PFX__ACM}--}%s"
else
    echo ">>> WARNING: LP_QE__CR__TS_NAME__PFX__ACM is unset or empty; keeping the raw suite name, which will not route to a component" >&2
    unset LP_IO__ET_PPP__NEW_TS_NAME
fi

################################################################################
# Test Overview
################################################################################
# This script deploys a sample OPP application and validates the integration
# with OPP bundle components (Quay, ACS).
#
# Test Cases:
#   1. Deploy OPP Application
#      - Deploys httpd-example application via deploy.sh
#      - Waits for deployment availability (implicitly waits for build)
#      - Verifies deployment is running successfully
#      - If ANY step fails, test fails and subsequent cases are skipped
#
#   2. Test ACS Integration
#      - Queries ACS API for httpd-example image
#      - Validates image appears in ACS with CVE scanning results
#      - Only runs if Case 1 passes
#
# Test Reporting:
#   - Results are recorded in JUnit XML format
#   - JUnit XML is generated on exit (via trap) regardless of test results
#   - The script exits 1 when any test case fails, 0 otherwise; per-case
#     results are visible in the Prow UI via JUnit reporting.  The step is
#     configured with best_effort: true, so a non-zero exit does not block
#     subsequent Prow test steps from running.
################################################################################

# cd to writable directory
cd /tmp/ || { echo "ERROR: Cannot cd to /tmp" >&2; exit 1; }

# Define all test cases with initial "skipped" status
typeset -A testStatus
typeset -A testDuration
typeset -A testFailureMsg

# All test cases that should appear in JUnit XML
typeset -a allTestCasesArr=(
    "deploy-opp-application"
    "test-acs-integration"
)

# Initialize all tests as failed (will be updated to passed if they succeed)
typeset test=""
for test in "${allTestCasesArr[@]}"; do
    testStatus["${test}"]="failed"
    testDuration["${test}"]=0
    testFailureMsg["${test}"]="Test did not run"
done

typeset -i startTime=0
startTime=$(date +%s)

# The ACS case records its own failure detail: the top-level caller cannot see
# which precondition failed, so RunTestCase2 leaves the reason here and the
# caller records the row with it.
typeset -g acsFailureMsg='ACS integration test failed'

# Function to record test result
function RecordTestResult () {
    typeset testName="${1:-}"; (($#)) && shift
    typeset status="${1:-}"; (($#)) && shift
    typeset failureMessage="${1:-}"; (($#)) && shift
    typeset duration="${1:-0}"; (($#)) && shift

    testStatus["${testName}"]="${status}"
    testDuration["${testName}"]="${duration}"
    testFailureMsg["${testName}"]="${failureMessage}"
    true
}

# Function to generate JUnit XML
function GenerateJunitXml () {
    typeset junitFile="${ARTIFACT_DIR}/junit_interop-acm-security-scan-ctr-img-acs-app-deployment.xml"
    typeset -i totalDuration=0
    totalDuration=$(( $(date +%s) - startTime ))

    # Count test results
    typeset -i totalTests=${#allTestCasesArr[@]}
    typeset -i failedTests=0
    typeset -i skippedTests=0
    typeset test=""

    for test in "${allTestCasesArr[@]}"; do
        if [ "${testStatus[${test}]}" = "failed" ]; then
            failedTests=$((failedTests + 1))
        elif [ "${testStatus[${test}]}" = "skipped" ]; then
            skippedTests=$((skippedTests + 1))
        fi
    done

    : "Generating JUnit XML Report"
    : "Total Tests: ${totalTests}"
    : "Failed Tests: ${failedTests}"
    : "Skipped Tests: ${skippedTests}"
    : "Passed Tests: $((totalTests - failedTests - skippedTests))"
    : "Duration: ${totalDuration}s"

    cat > "${junitFile}" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="interop-acm-security-scan-ctr-img-acs-app-deployment" tests="${totalTests}" failures="${failedTests}" errors="0" skipped="${skippedTests}" time="${totalDuration}">
EOF

    # Generate XML for each test case
    for test in "${allTestCasesArr[@]}"; do
        typeset status="${testStatus[${test}]}"
        typeset duration="${testDuration[${test}]}"
        typeset failureMsg="${testFailureMsg[${test}]}"

        if [ "${status}" = "failed" ]; then
            typeset escapedMsg=""
            escapedMsg=$(printf '%s\n' "${failureMsg}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
            echo "    <testcase name=\"${test}\" classname=\"interop-acm-security-scan-ctr-img-acs-app-deployment\" time=\"${duration}\"><failure message=\"${escapedMsg}\"/></testcase>" >> "${junitFile}"
        elif [ "${status}" = "skipped" ]; then
            typeset escapedMsg=""
            escapedMsg=$(printf '%s\n' "${failureMsg}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
            echo "    <testcase name=\"${test}\" classname=\"interop-acm-security-scan-ctr-img-acs-app-deployment\" time=\"${duration}\"><skipped message=\"${escapedMsg}\"/></testcase>" >> "${junitFile}"
        else
            echo "    <testcase name=\"${test}\" classname=\"interop-acm-security-scan-ctr-img-acs-app-deployment\" time=\"${duration}\"/>" >> "${junitFile}"
        fi
    done

    cat >> "${junitFile}" << EOF
  </testsuite>
</testsuites>
EOF

    : "JUnit XML generated at: ${junitFile}"
    cat "${junitFile}"
    true
}

################################################################################
# Test Case 1: Deploy OPP Application and Wait for Build/Deployment
################################################################################
function RunTestCase1 () {
    : "====== Test Case 1: Deploy OPP Application ======"

    # Download jq
    curl -fsSL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/jq || return 1
    chmod +x /tmp/jq || return 1

    # Clone and deploy
    git clone --depth 1 https://github.com/stolostron/policy-collection.git || return 1
    cd policy-collection/deploy/ || return 1
    echo 'y' | ./deploy.sh -p httpd-example -n policies -u https://github.com/gparvin/grc-demo.git -a e2e-opp || return 1

    # Wait for the e2e-opp namespace the policy deployment creates
    # (Best Practices: `oc wait --for=create` instead of a fixed sleep;
    # plain condition waits fail fast on NotFound).
    oc wait namespace/e2e-opp --for=create --timeout=5m || return 1

    # The policies create the BuildConfig and the Deployment after the
    # namespace: await their creation before using them.  Without this,
    # `oc start-build` has no BuildConfig to start, and the condition wait
    # below fails fast on a Deployment that does not exist yet (same Best
    # Practice as the namespace wait above).
    oc wait buildconfig/httpd-example -n e2e-opp --for=create --timeout=10m || return 1
    oc wait deployment/httpd-example -n e2e-opp --for=create --timeout=10m || return 1

    # RunTestCase1 executes under an if condition, so errexit is suspended
    # here: every failure must return explicitly.
    oc label managedcluster local-cluster oppapps=httpd-example --overwrite || return 1

    # Check initial status
    oc get policies -n policies | sed -n '/example/p'
    oc get build -n e2e-opp || true
    oc get po -n e2e-opp || true
    oc get deployment -n e2e-opp || true

    # Trigger build if needed
    typeset latestBuildName=""
    latestBuildName=$(oc get builds -n e2e-opp --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' || echo "")
    [ -z "${latestBuildName}" ] && { latestBuildName=$(oc start-build httpd-example -n e2e-opp -o name | cut -d'/' -f2) || return 1; }
    : "Monitoring build: ${latestBuildName}"

    # Wait for deployment (which implicitly waits for build to complete)
    : "Waiting for deployment to be available (timeout: 10m)..."
    if ! oc wait --for=condition=Available deployment/httpd-example -n e2e-opp --timeout=10m; then
        printf '%s\n' "ERROR: Deployment did not become available" >&2

        # Collect diagnostics to understand why deployment failed
        : "=== Build Status ==="
        typeset latestBuild=""
        latestBuild=$(oc get builds -n e2e-opp --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' || echo "")
        if [ -n "${latestBuild}" ]; then
            typeset buildStatus=""
            buildStatus=$(oc get build "${latestBuild}" -n e2e-opp -o jsonpath='{.status.phase}' || echo "Unknown")
            : "Latest build: ${latestBuild}"
            : "Build status: ${buildStatus}"

            if [ "${buildStatus}" != "Complete" ]; then
                : "=== Build Details ==="
                oc get build "${latestBuild}" -n e2e-opp -o yaml --ignore-not-found || true
                oc describe build "${latestBuild}" -n e2e-opp || true
                (oc get buildconfig httpd-example -n e2e-opp -o json --ignore-not-found | python3 -c "
import sys,json
bc=json.load(sys.stdin)
for t in bc.get('spec',{}).get('triggers',[]):
    for k in ('secret','secretReference'):
        t.pop(k,None)
        if 'generic' in t: t['generic'].pop(k,None)
        if 'github' in t: t['github'].pop(k,None)
json.dump(bc,sys.stdout,indent=2)
" 2>/dev/null) || true
                (oc describe buildconfig httpd-example -n e2e-opp 2>/dev/null | sed -E 's#(/webhooks/)[^/[:space:]]+#\1REDACTED#g') || true
            fi
        fi

        : "=== Events ==="
        oc get event -n e2e-opp || true

        : "=== Deployment Status ==="
        oc get deployment -n e2e-opp || true
        oc get deployment httpd-example -n e2e-opp -o yaml --ignore-not-found || true
        oc describe deployment httpd-example -n e2e-opp || true

        : "=== Pod Status ==="
        oc get po -n e2e-opp || true

        : "=== ImageStream Status ==="
        oc get is -n e2e-opp httpd-example -o yaml --ignore-not-found | awk '/status:/{n=11} n>0{print; n--}'

        : "=== Quay Integration Status ==="
        oc get quayintegration quay -o yaml || true
        oc get cm -n openshift-config opp-ingres-ca -o yaml || true
        oc get secret -n policies quay-integration --no-headers || true

        : "=== Quay Bridge Operator Logs ==="
        typeset operatorPod=""
        operatorPod=$(oc get pod -n openshift-operators -l name=quay-bridge-operator -o jsonpath='{.items[0].metadata.name}' || echo "")
        [ -n "${operatorPod}" ] && oc logs -n openshift-operators "${operatorPod}" -c manager --tail=100 || true

        return 1
    fi

    : "Deployment is available"

    # Capture the exact image reference the deployment runs, so the ACS
    # query in Test Case 2 matches this deployment's image and not any
    # other image with a similar name.
    typeset -g deployedImage=''
    deployedImage="$(oc get deployment httpd-example -n e2e-opp -o jsonpath='{.spec.template.spec.containers[0].image}')" || deployedImage=''

    # The digest the running container actually pulled.  A tag can be reused by
    # a later build while ACS still holds the older build's record under that
    # tag, so the ACS match anchors on this digest: the deployment spec alone
    # carries the reference that was requested, not the build that is running.
    # The selector comes from matchLabels, so it matches the pods of every
    # ReplicaSet of the deployment, and an Available deployment can still have
    # older pods running mid-rollout: wait for the rollout to finish and then
    # require a single digest, instead of taking the first digest listed.
    typeset -g deployedImageDigest=''
    typeset -g deployedDigestNote=''
    typeset podSelector=''
    podSelector="$(oc get deployment httpd-example -n e2e-opp -o jsonpath='{range $k, $v := .spec.selector.matchLabels}{$k}={$v},{end}' 2>/dev/null)" || podSelector=''
    podSelector="${podSelector%,}"
    typeset -i rolloutRc=0
    typeset digestList=''
    typeset -i digestCount=0
    if [[ -z "${podSelector}" ]]; then
        deployedDigestNote="the pod selector could not be read"
    else
        oc rollout status deployment/httpd-example -n e2e-opp --timeout=10m >/dev/null 2>&1 || rolloutRc=$?
        if (( rolloutRc != 0 )); then
            deployedDigestNote="the rollout had not completed (oc rollout status exited ${rolloutRc})"
        else
            digestList="$(oc get pods -n e2e-opp -l "${podSelector}" -o jsonpath='{range .items[?(@.status.phase=="Running")].status.containerStatuses[*]}{.imageID}{"\n"}{end}' 2>/dev/null \
                | sed -n 's/.*\(sha256:[0-9a-f]\{64\}\).*/\1/p' | sort -u)" || digestList=''
            digestCount=$(printf '%s\n' "${digestList}" | sed '/^$/d' | wc -l)
            if (( digestCount == 1 )); then
                deployedImageDigest="${digestList}"
            elif (( digestCount > 1 )); then
                deployedDigestNote="the running pods report ${digestCount} different image digests (${digestList//$'\n'/ })"
            else
                deployedDigestNote="no running pod reports an image digest"
            fi
        fi
    fi

    # Collect final status
    oc get build,po,deployment -n e2e-opp || true
    oc get is -n e2e-opp httpd-example -o yaml --ignore-not-found | awk '/status:/{n=6} n>0{print; n--}'

    return 0
}

################################################################################
# Test Case 2: Test ACS Integration
################################################################################
function RunTestCase2 () {
    : "====== Test Case 2: Test ACS Integration ======"
    : "NOTE: Waiting for ACS to scan the httpd-example image built in Test Case 1."
    acsFailureMsg='ACS integration test failed'

    # Fetch ACS credentials.  The admin password is written to an
    # ephemeral file inside a subshell with xtrace disabled (Best
    # Practices secret handling): it is never set as a main-shell
    # variable, never expanded in a trace, and never passed as a command
    # argument.  acsHost is a route name, not a credential.  Both reads are
    # checked here so a missing secret fails in seconds instead of burning
    # the ACS retry budget on an empty host or password.
    typeset acsHost=""
    typeset acsPassFile="/tmp/acs-admin-password"
    if ! acsHost=$(oc get secret -n stackrox sensor-tls -o json | /tmp/jq -r '.data."acs-host"' | base64 -d); then
        echo "ERROR: Could not read the ACS host from secret stackrox/sensor-tls" >&2
        return 1
    fi
    if [[ -z "${acsHost}" ]]; then
        echo "ERROR: Secret stackrox/sensor-tls carries no acs-host value" >&2
        return 1
    fi
    ( set +x
      oc get secret -n stackrox central-htpasswd -o json | /tmp/jq -r '.data.password' | base64 -d >"${acsPassFile}"
    ) || true
    if [[ ! -s "${acsPassFile}" ]]; then
        echo "ERROR: Could not read the ACS admin password from secret stackrox/central-htpasswd" >&2
        return 1
    fi

    # Query ACS for the image deployed by Test Case 1.  Match on the exact
    # repository and on the reference the deployment runs, so an older build
    # of the same application cannot satisfy the check.
    #
    # An unreadable deployment image used to leave the fallback repository
    # name in place, which turned the ACS match into a substring test over
    # every image in the registry.  Fail the case instead: without the
    # reference there is nothing to anchor the match to.
    if [[ -z "${deployedImage:-}" ]]; then
        acsFailureMsg="Could not read the image reference of deployment e2e-opp/httpd-example; the ACS image match has no reference to anchor on"
        printf '%s\n' "ERROR: ${acsFailureMsg}" >&2
        RecordTestResult "test-acs-integration" "failed" "${acsFailureMsg}" "0"
        return 1
    fi

    # Split the deployed reference into repository path and digest.  An
    # @-pinned image carries a digest; otherwise the tag is whatever follows
    # the last colon when that colon comes after the last slash, so a registry
    # port is not mistaken for a tag and is stripped from the repository path
    # before the name comparison.
    typeset deployedRepoPath="${deployedImage%%@*}"
    typeset deployedDigest=''
    typeset deployedLastSegment="${deployedRepoPath##*/}"
    if [[ "${deployedLastSegment}" == *:* ]]; then
        deployedRepoPath="${deployedRepoPath%:*}"
    fi
    if [[ "${deployedImage}" == *@* ]]; then
        deployedDigest="${deployedImage#*@}"
    fi
    # A tag is not evidence of which build was scanned: the deployment may run
    # a tag whose earlier build ACS already holds, so a tag-pinned deployment
    # anchors on the digest the running container pulled.
    if [[ -z "${deployedDigest}" && -n "${deployedImageDigest:-}" ]]; then
        deployedDigest="${deployedImageDigest}"
    fi
    if [[ -z "${deployedDigest}" ]]; then
        acsFailureMsg="Could not resolve the digest of the running image in deployment e2e-opp/httpd-example: ${deployedDigestNote:-no digest observed}; a tag alone cannot anchor the ACS image match"
        printf '%s\n' "ERROR: ${acsFailureMsg}" >&2
        RecordTestResult "test-acs-integration" "failed" "${acsFailureMsg}" "0"
        return 1
    fi
    # Compare the repository by its last two path components on both sides
    # (or the whole path when it is shorter): the same application seen from a
    # registry host, a namespace or a route host has the same trailing path,
    # while an unrelated repository that merely contains this name does not
    # match.  ACS record names always carry at least a namespace and a
    # repository, so the depth is capped at two.
    typeset -a deployedRepoParts=()
    IFS='/' read -ra deployedRepoParts <<< "${deployedRepoPath}"
    typeset -i deployedRepoCount=${#deployedRepoParts[@]}
    typeset -i deployedRepoDepth=2
    (( deployedRepoCount < 2 )) && deployedRepoDepth=${deployedRepoCount}
    (( deployedRepoDepth > 0 )) || deployedRepoDepth=1
    typeset deployedRepo=''
    typeset -i repoPart=0
    for (( repoPart = deployedRepoCount - deployedRepoDepth; repoPart < deployedRepoCount; repoPart++ )); do
        deployedRepo+="${deployedRepoParts[repoPart]}/"
    done
    deployedRepo="${deployedRepo%/}"

    # The repository and reference values are passed with --arg/--argjson, so
    # a name carrying jq quoting characters cannot rewrite the program.  A
    # digest-pinned deployment must find that digest (ACS reports it as the
    # image id) and a tag-pinned deployment must find that tag: a
    # repository-only match also accepts an older build of the same
    # application, which is a record ACS may have scanned long ago.
    # The matches are wrapped in an array so the caller always sees how many
    # records the filter produced.  The single record is read out of that
    # array only when its length is exactly one: reading `.id` and `.cves`
    # from a stream of records concatenated them, so two records could satisfy
    # the guard below between them even when neither carried a CVE count.
    # The jq programs are single-quoted on purpose: they are not shell
    # expansions, and every value reaches jq as an argument.
    # shellcheck disable=SC2016
    typeset jqFilter='
def repopath: sub("@.*$"; "") | sub(":[^/]*$"; "");
def lastn($d): split("/") | .[-$d:] | join("/");
[ .images[]
  | select((((.name // "") | repopath | lastn($depth)) == $repo))
'
    if [[ -n "${deployedDigest}" ]]; then
        # shellcheck disable=SC2016
        jqFilter+='  | select(((.name // "") | contains("@" + $digest)) or ((.id // "") == $digest))
'
    fi
    # shellcheck disable=SC2016
    jqFilter+=']
'

    # TLS verification for the ACS Central API.  The admin credential is only
    # ever sent over a connection whose certificate is verified, so a CA that
    # checks the route is resolved before the first credential-bearing
    # request: Central's own serving CA first (the central route terminates TLS
    # in the pod, so the client sees Central's certificate rather than a router
    # certificate), then the ingress router CA, then the service CA bundle
    # mounted in the pod.  There is deliberately no -k fallback: an unverified
    # connection would hand the admin password to an on-path attacker, and an
    # unverifiable route fails the case instead.
    typeset centralCa=''
    centralCa="$(oc get secret central-tls -n stackrox -o jsonpath='{.data.ca\.pem}' 2>/dev/null | base64 -d 2>/dev/null)" || centralCa=''
    typeset -a acsCaCandidates=()
    if [[ -n "${centralCa}" ]]; then
        printf '%s\n' "${centralCa}" > /tmp/acs-central-ca.crt
        acsCaCandidates+=( /tmp/acs-central-ca.crt )
    fi
    typeset ingressCaBundle=''
    ingressCaBundle="$(oc get configmap default-ingress-cert -n openshift-config-managed -o jsonpath='{.data.ca-bundle\.crt}' 2>/dev/null)" || ingressCaBundle=''
    if [[ -n "${ingressCaBundle}" ]]; then
        printf '%s\n' "${ingressCaBundle}" > /tmp/acs-ingress-ca.crt
        acsCaCandidates+=( /tmp/acs-ingress-ca.crt )
    fi
    typeset saCaBundle='/var/run/secrets/kubernetes.io/serviceaccount/ca.crt'
    if [[ -f "${saCaBundle}" ]]; then
        acsCaCandidates+=( "${saCaBundle}" )
    fi
    typeset acsCaFile=''
    typeset candidateCa=''
    typeset tlsProbe=''
    if (( ${#acsCaCandidates[@]} > 0 )); then
        for candidateCa in "${acsCaCandidates[@]}"; do
            tlsProbe="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 15 --max-time 30 --cacert "${candidateCa}" "https://${acsHost}/v1/ping")" || tlsProbe='000'
            if [[ -n "${tlsProbe}" && "${tlsProbe}" != '000' ]]; then
                acsCaFile="${candidateCa}"
                break
            fi
        done
    fi
    if [[ -z "${acsCaFile}" ]]; then
        acsFailureMsg="Could not verify the ACS Central route certificate for ${acsHost} with Central's serving CA (secret stackrox/central-tls), the ingress router CA or the service CA bundle; refusing to send the admin credential over unverified TLS"
        printf '%s\n' "ERROR: ${acsFailureMsg}" >&2
        rm -f "${acsPassFile}" /tmp/acs-ingress-ca.crt /tmp/acs-central-ca.crt
        RecordTestResult "test-acs-integration" "failed" "${acsFailureMsg}" "0"
        return 1
    fi
    typeset -a acsTlsOpts=( --cacert "${acsCaFile}" )

    typeset -i retries=10
    typeset -i retryInterval=30
    typeset isImageFound=false
    typeset httpdImageJson="" imageId="" cves="" image=""
    typeset -i matchCount=0
    typeset -i multiMatchCount=0

    : "Waiting for httpd-example image to appear in ACS (max $((retries * retryInterval))s)..."
    typeset -i attempt=0
    for ((attempt = 1; attempt <= retries; ++attempt)); do
        : "Attempt ${attempt}/${retries}: Querying ACS for httpd-example image..."
        # The query runs in a command-substitution subshell with xtrace
        # disabled and curl reads the password from a process-substitution
        # config, so the credential appears in neither the trace nor argv.
        httpdImageJson="$(
            set +x
            curl -fsSL "${acsTlsOpts[@]}" --connect-timeout 15 --max-time 60 \
                --config <(printf 'user = "admin:%s"\n' "$(cat "${acsPassFile}")") \
                "https://${acsHost}/v1/images" | /tmp/jq --arg repo "${deployedRepo}" --argjson depth "${deployedRepoDepth}" \
                    --arg digest "${deployedDigest}" "${jqFilter}"
        )"
        # Read the record only out of a single-element answer.  Two or more
        # matching records are named and retried instead of being read: jq
        # would otherwise concatenate their fields, and a record whose cves is
        # null could satisfy the guard below through a sibling record.
        matchCount=$(echo "${httpdImageJson}" | /tmp/jq 'length')
        if (( matchCount > 1 )); then
            multiMatchCount="${matchCount}"
            imageId=''
            cves=''
            : "Attempt ${attempt}/${retries}: ${matchCount} ACS records match ${deployedRepo}; waiting for a single matching record"
        elif (( matchCount == 1 )); then
            imageId=$(echo "${httpdImageJson}" | /tmp/jq '.[0].id // ""')
            cves=$(echo "${httpdImageJson}" | /tmp/jq '.[0].cves')
            # A matching record only proves ACS ingested the image once it
            # carries both a real image id and a numeric CVE count: jq renders
            # a missing field as the literal `null`, which is neither.  A
            # completed scan with zero CVEs is accepted (0 is a number).
            if [ "${imageId}" != "" ] && [ "${imageId}" != "null" ] && [ "${cves}" != "" ] && [ "${cves}" != "null" ]; then
                image=$(echo "${httpdImageJson}" | /tmp/jq '.[0].name // ""')
                : "Success: Found ${cves} CVEs for image ${image}"
                isImageFound=true
                break
            fi
        fi

        [ "${attempt}" -lt "${retries}" ] && sleep "${retryInterval}"
    done

    rm -f "${acsPassFile}" /tmp/acs-ingress-ca.crt /tmp/acs-central-ca.crt

    if [ "${isImageFound}" != true ]; then
        # Name the multi-match condition on exhaustion: a registry that keeps
        # answering with several records is a different fault from a scan that
        # never happened, and the row has to say which one it was.
        if (( multiMatchCount > 1 )); then
            acsFailureMsg="ACS returned ${multiMatchCount} matching records for ${deployedRepo} after $((retries * retryInterval))s; the check accepts exactly one record"
            printf '%s\n' "ERROR: ${acsFailureMsg}" >&2
        fi
        return 1
    fi

    return 0
}

################################################################################
# Test Execution Setup
################################################################################
# Load ExitTrap library for Component Readiness JUnit remapping
# Per Best Practices: Use exact pattern from library documentation.
eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" \
        https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh
)"

# Post-process the JUnit XML for Component Readiness routing.  Guarded on
# purpose: this runs from the EXIT trap, and an unloaded helper (download
# failure) or a post-processing failure must not overwrite the script's
# exit status (the unguarded call fails the trap with 127 and turns a
# passing run into a failure).  The merged file name is passed explicitly:
# the library default (jUnit.xml) is not picked up by the prow JUnit viewer
# (lowercase junit prefix required) and collides with other steps in
# shared storage.
PostProcessJunit () {
    if type -t ExitTrap--PostProcessPrep 1>/dev/null; then
        ExitTrap--PostProcessPrep junit--interop-acm-security-scan-ctr-img-acs-app-deployment.xml ||
            printf '%s\n' "WARNING: junit post-processing failed" >&2
    else
        printf '%s\n' "WARNING: ExitTrap--PostProcessPrep not available, skipping junit remapping" >&2
    fi
    true
}

# Set trap to generate JUnit XML and remap for Component Readiness
# Integrates existing GenerateJunitXml function with ExitTrap library
# errexit is off inside the trap so one failing report step cannot skip the
# rest, and the credential file is removed here so it does not survive an
# early return.
trap '{(
    set +e
    GenerateJunitXml
    _propagate_junit
    PostProcessJunit
    rm -f /tmp/acs-admin-password
    true
)}' EXIT

################################################################################
# Pre-flight Checks
################################################################################
: "====== Pre-flight Check: QuayIntegration ======"

# Distinguish between "CRD not installed" (skip) and "CRD exists but CR
# missing" (fail).  On OCP versions where the Quay Bridge Operator is not
# available in the catalog the QuayIntegration CRD will be absent entirely;
# that is an environment limitation, not a test failure.
typeset apiOutput=""
typeset -i apiRc=0
apiOutput=$(oc api-resources --api-group=quay.redhat.com) || apiRc=$?

if ((apiRc != 0)); then
    printf '%s\n' "WARNING: oc api-resources failed (rc=${apiRc}) - cannot determine CRD presence, falling through to CR check" >&2
elif ! grep -qi quayintegration <<< "${apiOutput}"; then
    : "QuayIntegration CRD is not installed on this cluster."
    : "Quay Bridge Operator is not available - skipping OPP app tests."

    for test in "${allTestCasesArr[@]}"; do
        testStatus["${test}"]="skipped"
        testFailureMsg["${test}"]="QuayIntegration CRD not available - Quay Bridge Operator not installed"
    done

    exit 0
fi

typeset getOutput=""
typeset -i getRc=0
getOutput=$(oc get quayintegration quay --ignore-not-found -o name) || getRc=$?

if ((getRc != 0)); then
    printf '%s\n' "WARNING: oc get quayintegration failed (rc=${getRc}) - cluster API error" >&2
    printf '%s\n' "Marking all test cases as failed." >&2

    for test in "${allTestCasesArr[@]}"; do
        testStatus["${test}"]="failed"
        testFailureMsg["${test}"]="oc get quayintegration failed (rc=${getRc}) - cluster API error"
    done

    exit 1
elif [[ -z "${getOutput}" ]]; then
    printf '%s\n' "ERROR: QuayIntegration CRD exists but CR 'quay' not found!" >&2
    printf '%s\n' "OPP bundle components are not properly configured." >&2
    printf '%s\n' "Cannot proceed with testing - marking all test cases as failed." >&2

    for test in "${allTestCasesArr[@]}"; do
        testStatus["${test}"]="failed"
        testFailureMsg["${test}"]="QuayIntegration CR 'quay' not found - OPP bundle not configured"
    done

    exit 1
fi

: "QuayIntegration quay found"
oc get quayintegration quay -o yaml --ignore-not-found

################################################################################
# Execute Test Cases
################################################################################
# Run Test Case 1
typeset -i case1Start=0
case1Start=$(date +%s)
if RunTestCase1; then
    typeset -i case1Duration=0
    case1Duration=$(( $(date +%s) - case1Start ))
    RecordTestResult "deploy-opp-application" "passed" "" "${case1Duration}"
    : "Test Case 1 (Deploy OPP Application) Result: PASSED"

    # Run Test Case 2 (ACS Integration)
    typeset -i case2Start=0
    case2Start=$(date +%s)
    if RunTestCase2; then
        typeset -i case2Duration=0
        case2Duration=$(( $(date +%s) - case2Start ))
        RecordTestResult "test-acs-integration" "passed" "" "${case2Duration}"
        : "Test Case 2 (Test ACS Integration) Result: PASSED"
    else
        typeset -i case2Duration=0
        case2Duration=$(( $(date +%s) - case2Start ))
        RecordTestResult "test-acs-integration" "failed" "${acsFailureMsg}" "${case2Duration}"
        : "Test Case 2 (Test ACS Integration) Result: FAILED"
    fi
else
    typeset -i case1Duration=0
    case1Duration=$(( $(date +%s) - case1Start ))
    : "Test Case 1 (Deploy OPP Application) Result: FAILED"
    : "Test Case 1 failed, skipping remaining test cases..."
    RecordTestResult "deploy-opp-application" "failed" "OPP application deployment failed" "${case1Duration}"
    RecordTestResult "test-acs-integration" "skipped" "Skipped: prerequisite Test Case 1 (deploy) failed" "0"
fi

: "====== Test Summary ======"
: "All test results will be available in JUnit XML report"

# Exit based on whether any test failed
typeset _overall_status="PASS"
for test in "${allTestCasesArr[@]}"; do
    if [[ "${testStatus[${test}]}" == "failed" ]]; then
        _overall_status="FAIL"
        break
    fi
done

if [[ "${_overall_status}" == "PASS" ]]; then
    exit 0
else
    exit 1
fi
