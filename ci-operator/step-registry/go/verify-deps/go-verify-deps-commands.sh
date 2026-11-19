#!/bin/bash
set -o errexit # Nonzero exit code of any of the commands below will fail the test.
set -o nounset
set -o pipefail

die_general() {
    echo "ERROR: An discrepancy was found in go dependency metadata or it could not"
    echo "be checked successfully. Common failures:"
    echo "- go mod tidy failed to run with the repository's configured \"build root\"."
    echo "  Errors output like 'go.mod file indicates go 1.21, but maximum supported version is 1.17'"
    echo "  indicate your go.mod requests 1.21, but your Test Platform build root is based"
    echo "  on a go 1.17 builder image. The following documentation explains build root configuration:"
    echo "  https://docs.ci.openshift.org/docs/architecture/images/#controlling-go-versions-in-component-repositories"
    echo "  Generally, you will want 'build_root.from_repository: true' in your"
    echo "  ci-operator configuration file and to manage your build root in your component"
    echo "  repository in .ci-operator.yaml (.ci-operator.yaml is ignored if from_repository: true"
    echo "  is not set)."
    echo ""
    echo "- go.mod information may be incomplete / inaccurate."
    echo ""
    echo "- /vendor may not contain the versions declared in go.mod or certain"
    echo "  files which should be in /vendor have not been checked in. This can"
    echo "  happen due to .gitignore rules ignoring files in /vendor ."
    echo ""
    echo "- You may be trying to introduce a code change in vendored content. This"
    echo "  is not permitted. If you must make custom changes to a module,"
    echo "  there are two options:"
    echo "  1. Use a local go.mod replace statement. For example:"
    echo "     replace example.com/foo/bar => ../bar-modified"
    echo "  2. When multiple repositories need the same modification, it may prove easier"
    echo "     to fork the upstream dependency into github.com/openshift, customize"
    echo "     a branch, and vendor the fork in your go.mod. For example:"
    echo "     https://github.com/openshift/golang-crypto/tree/patch_v0.33.openshift.1"
    echo ""
    echo "Job logs show files that have been added or modified by running"
    echo "\"go mod tidy\" and \"go mod vendor\" (or \"go work vendor\" for workspaces)."
    echo "You can run these commands locally and check for discrepancies with"
    echo "> git status --porcelain --ignored".
    echo ""
    echo "This check does not respect .gitignore entries. If .gitignore is masking"
    echo "files in vendor/, the check will fail. Update your .gitignore file to"
    echo "prevent it from acting on files in vendor/."
    echo ""
    echo "In order for the OpenShift Build and Release Team (ART) to create"
    echo "productized builds, all dependencies must be present and consistent."
    echo "Please correct these discrepancies before merging the PR."
    exit 1
}

die_modlist() {
    echo "ERROR: go list -mod=readonly -m all failed with the message listed above."
    echo "Cachito used in ART builds will fail to resolve dependencies offline."
    echo "Typically, a pinned version is missing in go.mod, e.g.:"
    echo "    replace k8s.io/foo => k8s.io/foo v0.26.0"
    exit 1
}

# ---------------------------------------------------------------------------
# Go module proxy availability check (ART-26147)
#
# Validate that a repo's pinned Go module pseudo-versions are actually
# resolvable on the Go module proxy BEFORE a build runs. Today an unavailable
# commit only surfaces much later as an opaque 404 inside the ART/Konflux
# hermeto prefetch while fetching the module's .zip. Catching it here produces a
# clear, actionable message instead.
# ---------------------------------------------------------------------------

# Escape a module path or version for the Go module proxy, per
# https://go.dev/ref/mod#goproxy-protocol : every uppercase ASCII letter is
# replaced by "!" followed by its lowercase form (e.g. github.com/Azure ->
# github.com/!azure). Implemented in pure bash (no python dependency).
goproxy_escape() {
    local s="$1" out="" i c
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [A-Z]) out+="!${c,,}" ;;
            *)     out+="$c" ;;
        esac
    done
    printf '%s' "$out"
}

# Redact a URL for DISPLAY only: strip any userinfo (user:pass@) and the query
# string (and fragment) so credentials embedded in a proxy URL never reach the
# CI logs. The actual HTTP probe always uses the full, unredacted URL.
goproxy_redact_url() {
    local u="$1"
    # Drop fragment and query string.
    u="${u%%[#]*}"
    u="${u%%[?]*}"
    # Drop userinfo between scheme:// and the host (the first '@' before any '/').
    # The module-proxy "/@v/" segment is safe because its '@' follows a '/'.
    if [[ "$u" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*://)([^/@]*@)?(.*)$ ]]; then
        u="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"
    fi
    printf '%s' "$u"
}

# Return 0 if a module path is private per GONOPROXY/GOPRIVATE patterns.
# Pure-bash, safe (broad) approximation of Go's path.Match-based semantics:
#   - pattern without '*': match when path == pattern OR path starts with
#     pattern + "/".
#   - pattern with '*': glob-match (extglob) the path against the pattern and
#     against the prefix form (pattern + "/*").
# Callers enable extglob before invoking. Arguments: <path> <pattern>...
goproxy_path_is_private() {
    local path="$1"
    shift
    local pattern
    for pattern in "$@"; do
        [[ -n "$pattern" ]] || continue
        if [[ "$pattern" == *"*"* ]]; then
            # shellcheck disable=SC2053 # glob match of the pattern is intentional here
            if [[ "$path" == $pattern || "$path" == $pattern/* ]]; then
                return 0
            fi
        else
            if [[ "$path" == "$pattern" || "$path" == "$pattern"/* ]]; then
                return 0
            fi
        fi
    done
    return 1
}

# Default HTTP HEAD probe using curl. Prints the HTTP status code (or 000 on a
# transport error). NO -f, so a 404 still exits 0 and prints the code. Follows
# redirects (-L) so the terminal status is classified rather than a 3xx. The
# caller guards against errexit (code=$(...) || code=000).
goproxy_probe_curl() {
    local url="$1" code
    code=$(curl -sS -o /dev/null -I -L --max-redirs 5 -w '%{http_code}' --max-time 15 "$url") || code=000
    printf '%s' "$code"
}

# Fallback HTTP probe using wget. Prints the HTTP status code (or 000).
goproxy_probe_wget() {
    local url="$1" out code
    out=$(wget -S --spider --timeout=15 -t 1 "$url" 2>&1) || true
    code=$(printf '%s\n' "$out" | awk '/^[[:space:]]*HTTP\// {c=$2} END {print c}')
    [[ -n "$code" ]] || code=000
    printf '%s' "$code"
}

# Print the remediation message for modules whose pinned pseudo-version is not
# resolvable on the Go module proxy. The first argument is the redacted proxy
# base URL; each remaining argument is a pre-formatted
# "path|version|commit|url|status" record (url is already redacted for display).
goproxy_report_missing() {
    local rbase="$1"
    shift
    local entry path version commit url status
    echo "ERROR: go.mod pins one or more Go module pseudo-versions that the Go"
    echo "module proxy cannot resolve. Each one below would make the ART/Konflux"
    echo "hermeto prefetch fail later with an opaque 404 while fetching the"
    echo "module's .zip, so the build is stopped here instead."
    echo ""
    echo "Go module proxy base URL (redacted): ${rbase}"
    echo ""
    echo "Unresolvable module pseudo-version(s):"
    for entry in "$@"; do
        IFS='|' read -r path version commit url status <<< "$entry"
        echo "- module:  ${path}"
        echo "  version: ${version}"
        echo "  commit:  ${commit}"
        echo "  proxy:   ${url}"
        echo "  status:  ${status}"
    done
    echo ""
    echo "Likely cause:"
    echo "- This typically happens with very large dependency repositories when the"
    echo "  pinned commit is far from the nearest semver tag: the proxy cannot"
    echo "  compute or serve a pseudo-version for a commit with no nearby tag, so"
    echo "  the request 404s."
    echo ""
    echo "How to fix:"
    echo "  1. Ask the maintainers of the dependency repository to push a semver"
    echo "     tag on (or after) the pinned commit, so a nearby tag exists."
    echo "  2. After the tag is published (allow a few minutes for proxy"
    echo "     propagation), update this repo to require the tag instead of the"
    echo "     pseudo-version:"
    echo "       - plain require:   go get <module>@<new-tag>"
    echo "       - replace directive: go mod edit -replace <old>=<target>@<new-tag>"
    echo "     then run 'go mod tidy' (and 'go mod vendor' if this repo vendors)"
    echo "     to record the change."
    echo "  3. IMPORTANT: 'go mod tidy' alone will NOT swap an existing pinned"
    echo "     pseudo-version or replace directive to the new tag. You must set the"
    echo "     version explicitly first (step 2)."
    echo ""
    echo "Alternatively, simply re-running the build after the tag exists may"
    echo "succeed: the original pseudo-version can become resolvable once a nearby"
    echo "tag is present on the proxy."
}

# Verify that pinned Go module pseudo-versions (and, optionally, all required /
# replaced module versions) are resolvable on the Go module proxy BEFORE a build
# runs. See ART-26147.
check_goproxy_availability() {
    local check_enabled="${CHECK_GOPROXY_AVAILABILITY:-true}"
    # 1. Only run when go.mod exists AND the check is enabled.
    if [[ ! -f "go.mod" || "${check_enabled}" != "true" ]]; then
        return 0
    fi

    local proxy_url="${GOPROXY_AVAILABILITY_URL:-}"
    local retries="${GOPROXY_CHECK_RETRIES:-5}"
    local retry_delay="${GOPROXY_CHECK_RETRY_DELAY_SECONDS:-10}"
    local check_all="${GOPROXY_CHECK_ALL_VERSIONS:-false}"
    local strict="${GOPROXY_CHECK_STRICT:-false}"
    local deadline="${GOPROXY_CHECK_DEADLINE_SECONDS:-120}"

    echo "Checking that pinned Go module versions are resolvable on the Go module proxy (ART-26147)."

    # Determine the proxy base URL: explicit override, else auto-detect from
    # GOPROXY, else fall back to the public proxy.
    local proxy_base="${proxy_url}"
    if [[ -z "${proxy_base}" ]]; then
        # GOPROXY is a ","/"|"-separated list; take the first http(s) entry and
        # skip the "direct"/"off" keywords.
        local goproxy_env
        goproxy_env="$(go env GOPROXY 2>/dev/null || true)"
        local -a gp_entries=()
        IFS=',|' read -r -a gp_entries <<< "${goproxy_env}"
        local entry
        for entry in "${gp_entries[@]}"; do
            if [[ "${entry}" == http://* || "${entry}" == https://* ]]; then
                proxy_base="${entry}"
                break
            fi
        done
        [[ -n "${proxy_base}" ]] || proxy_base="https://proxy.golang.org"
    fi
    proxy_base="${proxy_base%/}"
    # Redacted form for display (never log credentials embedded in the URL).
    local rproxy_base
    rproxy_base="$(goproxy_redact_url "${proxy_base}")"
    echo "Using Go module proxy base URL: ${rproxy_base}"

    # Select the probe command. GOPROXY_PROBE_CMD overrides the default (this is
    # what the embedded self-test mocks). If neither curl nor wget is available,
    # warn and skip the whole check rather than failing the build for a missing
    # tool.
    local probe_cmd=""
    if [[ -n "${GOPROXY_PROBE_CMD:-}" ]]; then
        probe_cmd="${GOPROXY_PROBE_CMD}"
    elif command -v curl >/dev/null 2>&1; then
        probe_cmd="goproxy_probe_curl"
    elif command -v wget >/dev/null 2>&1; then
        probe_cmd="goproxy_probe_wget"
    else
        echo "WARNING: neither 'curl' nor 'wget' is available; skipping Go module proxy availability check."
        return 0
    fi

    # 2. Enumerate candidate path@version pairs from go.mod, offline:
    #      - every Require[].Path@Version whose path is NOT replaced (see below).
    #      - every Replace[] whose New.Version is non-empty AND New.Path is a
    #        remote module (does NOT start with "." or "/"), i.e. not a local
    #        path replacement.
    #    Replace-aware requires: if a required module path has an applicable
    #    replace, the original require version is dropped. A local-path replace
    #    removes the module entirely; a remote replace's target version is
    #    enumerated separately via its New entry. Unreplaced requires are kept.
    #    `go mod edit -json` emits deterministic, tab-indented JSON; the awk
    #    below walks it without needing jq/python.
    local candidates
    candidates="$(go mod edit -json | awk '
        function val(line,   v) {
            v = line
            sub(/^[^:]*:[[:space:]]*"/, "", v)
            sub(/".*$/, "", v)
            return v
        }
        BEGIN { nr = 0 }
        /"Require": \[/ { section = "Require"; next }
        /"Replace": \[/ { section = "Replace"; subobj = ""; next }
        /^[[:space:]]*\][,]?[[:space:]]*$/ { section = ""; subobj = ""; next }
        section == "Require" && /"Path":/ { curpath = val($0); next }
        section == "Require" && /"Version":/ {
            if (curpath != "") { rp[nr] = curpath; rv[nr] = val($0); nr++ }
            curpath = ""
            next
        }
        section == "Replace" && /"Old": \{/ { subobj = "Old"; next }
        section == "Replace" && /"New": \{/ { subobj = "New"; newpath = ""; next }
        section == "Replace" && subobj == "Old" && /"Path":/ { replaced[val($0)] = 1; next }
        section == "Replace" && subobj == "New" && /"Path":/ { newpath = val($0); next }
        section == "Replace" && subobj == "New" && /"Version":/ {
            nv = val($0)
            if (nv != "" && newpath !~ "^[./]") print newpath "@" nv
            subobj = ""
            next
        }
        END {
            for (i = 0; i < nr; i++) {
                if (!(rp[i] in replaced)) print rp[i] "@" rv[i]
            }
        }
    ' | sort -u)"

    if [[ -z "${candidates}" ]]; then
        echo "No module versions found to check; skipping Go module proxy availability check."
        return 0
    fi

    # 3. A pseudo-version ends in a 14-digit UTC timestamp and a 12-hex commit
    #    prefix, optionally followed by "+incompatible". The separator before the
    #    timestamp is "-" for the base-less form (v0.0.0-TIMESTAMP-hash) and "."
    #    for the pre-release / post-release forms (vX.Y.Z-pre.0.TIMESTAMP-hash and
    #    vX.Y.Z-0.TIMESTAMP-hash). Matching both separators is required to detect
    #    the real ART-26147 pin (v1.37.0-alpha.0.0.20261110024958-4608138db381),
    #    whose timestamp is dot-separated. Ordinary tagged versions (including a
    #    bare vX.Y.Z+incompatible) are excluded. Unless GOPROXY_CHECK_ALL_VERSIONS
    #    =true we check only pseudo-versions.
    local pseudo_re='[-.][0-9]{14}-[0-9a-f]{12}([+]incompatible)?$'

    # Private-module exclusion patterns: GONOPROXY (which already defaults to
    # GOPRIVATE), falling back to GOPRIVATE when GONOPROXY is empty. These modules
    # are not served by the public proxy, so never probe or fail them.
    local nopriv
    nopriv="$(go env GONOPROXY 2>/dev/null || true)"
    [[ -n "${nopriv}" ]] || nopriv="$(go env GOPRIVATE 2>/dev/null || true)"
    local -a priv_patterns=()
    [[ -z "${nopriv}" ]] || IFS=',' read -r -a priv_patterns <<< "${nopriv}"
    shopt -s extglob

    # Overall time budget and proxy-outage short-circuit.
    local outage_threshold=3
    local consecutive_000=0
    local budget_stop=""          # "deadline" or "outage" once we stop probing early
    local start_ts=${SECONDS}

    local -a missing=() inconclusive=() budget_skipped=() private_skipped=()
    local cand path version commit epath eversion url rurl
    local attempt code lastclass result delay elapsed
    while IFS= read -r cand; do
        [[ -n "${cand}" ]] || continue
        path="${cand%@*}"
        version="${cand##*@}"

        # Pseudo-version filter (unless checking all versions).
        if [[ "${check_all}" != "true" ]]; then
            [[ "${version}" =~ ${pseudo_re} ]] || continue
        fi

        # Skip private modules; never probe or fail them.
        if (( ${#priv_patterns[@]} > 0 )) && goproxy_path_is_private "${path}" "${priv_patterns[@]}"; then
            private_skipped+=( "${path}" )
            continue
        fi

        # Stop probing once the overall wall-clock budget is exceeded.
        if [[ -z "${budget_stop}" ]]; then
            elapsed=$(( SECONDS - start_ts ))
            if (( deadline > 0 && elapsed >= deadline )); then
                budget_stop="deadline"
            fi
        fi
        if [[ -n "${budget_stop}" ]]; then
            echo "  INCONCLUSIVE ${path}@${version} (skipped: ${budget_stop})"
            budget_skipped+=( "${path}|${version}|${budget_stop}" )
            continue
        fi

        # 4. Build the escaped proxy URL for the .info endpoint; redact for display.
        epath="$(goproxy_escape "${path}")"
        eversion="$(goproxy_escape "${version}")"
        url="${proxy_base}/${epath}/@v/${eversion}.info"
        rurl="$(goproxy_redact_url "${url}")"
        # The commit is the trailing 12-hex of the pseudo-version.
        commit="${version##*-}"
        commit="${commit%+incompatible}"

        # 5/6. HEAD probe with a retry/backoff loop:
        #        200          => available (stop)
        #        404/410      => retry (absorb proxy propagation delay); still
        #                        404/410 after the last attempt => MISSING
        #        anything else => retry; still failing after last attempt
        #                        (000 network / 5xx / 429) => INCONCLUSIVE
        result=""
        lastclass="INCONCLUSIVE"
        for (( attempt = 1; attempt <= retries; attempt++ )); do
            code=$("${probe_cmd}" "${url}") || code=000
            if [[ "${code}" == "200" ]]; then
                result="AVAILABLE"
                break
            elif [[ "${code}" == "404" || "${code}" == "410" ]]; then
                lastclass="MISSING"
            else
                lastclass="INCONCLUSIVE"
            fi
            if (( attempt < retries )); then
                delay=$(( retry_delay * attempt ))
                (( delay > 0 )) && sleep "${delay}"
            fi
        done
        [[ -n "${result}" ]] || result="${lastclass}"

        # Track consecutive transport failures to detect a proxy-wide outage.
        if [[ "${code}" == "000" ]]; then
            consecutive_000=$(( consecutive_000 + 1 ))
        else
            consecutive_000=0
        fi

        case "${result}" in
            AVAILABLE)
                echo "  OK           ${path}@${version} (${code})"
                ;;
            MISSING)
                echo "  MISSING      ${path}@${version} (${code}) ${rurl}"
                missing+=( "${path}|${version}|${commit}|${rurl}|${code}" )
                ;;
            *)
                echo "  INCONCLUSIVE ${path}@${version} (${code}) ${rurl}"
                inconclusive+=( "${path}|${version}|${commit}|${rurl}|${code}" )
                ;;
        esac

        # Proxy-wide outage short-circuit: after enough consecutive transport
        # failures, stop probing the rest and treat them as inconclusive.
        if (( consecutive_000 >= outage_threshold )); then
            budget_stop="outage"
        fi
    done <<< "${candidates}"

    # Report private-module skips (paths only; never versions or URLs).
    if (( ${#private_skipped[@]} > 0 )); then
        local priv_list
        priv_list="$(printf '%s\n' "${private_skipped[@]}" | sort -u | tr '\n' ' ')"
        echo "Skipping private module(s) matched by GONOPROXY/GOPRIVATE: ${priv_list}"
    fi

    # 7. Decide the outcome.
    if (( ${#missing[@]} > 0 )); then
        goproxy_report_missing "${rproxy_base}" "${missing[@]}"
        exit 1
    fi

    local e reason
    if (( ${#inconclusive[@]} > 0 )); then
        echo "WARNING: could not conclusively verify ${#inconclusive[@]} module version(s) on the Go module proxy (transient/non-404 responses):"
        for e in "${inconclusive[@]}"; do
            IFS='|' read -r path version commit rurl code <<< "${e}"
            echo "  - ${path}@${version} (${code}) ${rurl}"
        done
    fi

    if (( ${#budget_skipped[@]} > 0 )); then
        echo "WARNING: stopped probing ${#budget_skipped[@]} module version(s) early (${budget_stop}); treated as inconclusive and NOT failing the check:"
        for e in "${budget_skipped[@]}"; do
            IFS='|' read -r path version reason <<< "${e}"
            echo "  - ${path}@${version} (${reason})"
        done
    fi

    # Strict mode fails on genuinely inconclusive probe results, but never on
    # budget/outage skips (an infrastructure/time limit, not a dependency issue).
    if (( ${#inconclusive[@]} > 0 )) && [[ "${strict}" == "true" ]]; then
        echo "ERROR: GOPROXY_CHECK_STRICT=true; treating inconclusive results as a failure."
        exit 1
    fi

    if (( ${#inconclusive[@]} > 0 || ${#budget_skipped[@]} > 0 )); then
        echo "Continuing (set GOPROXY_CHECK_STRICT=true to fail on inconclusive results; budget/outage skips never fail)."
        return 0
    fi

    echo "All checked Go module versions are resolvable on the Go module proxy."
}

# ---------------------------------------------------------------------------
# Embedded self-test (ART-26147). Satisfies the requirement to store the failing
# commit and go.mod for testing without adding extra files to the step dir (the
# registry loader rejects anything that is not a recognized file type). Runs
# only when explicitly requested ("--self-test" or GOPROXY_SELF_TEST=1); it
# never runs in normal CI (no args, env unset).
#
# Note: no shell EXIT handler is used here (it would make ci-operator require a
# grace_period on the step); the temp dir is removed explicitly before return.
# ---------------------------------------------------------------------------
run_self_test() {
    local tmpdir rc out failed=0 origdir
    origdir="${PWD}"
    tmpdir="$(mktemp -d)"

    # Fixture go.mod derived from github.com/openshift/origin release-5.0,
    # commit 4608138db381, reproducing the pinned openshift/kubernetes
    # pseudo-versions that were not resolvable on the Go module proxy (ART-26147).
    cat > "${tmpdir}/go.mod" <<'EOF'
// Fixture derived from github.com/openshift/origin release-5.0 (commit 4608138db381).
// It reproduces the pinned openshift/kubernetes pseudo-versions that were not
// resolvable on the Go module proxy, causing ART/Konflux hermeto prefetch to 404.
module github.com/openshift/origin

go 1.22.0

require (
	github.com/stretchr/testify v1.11.1
	github.com/example/benign v0.0.0-20240229000000-abcdef123456
)

replace (
	k8s.io/api => github.com/openshift/kubernetes/staging/src/k8s.io/api v0.0.0-20261110024958-4608138db381
	k8s.io/apimachinery => github.com/openshift/kubernetes/staging/src/k8s.io/apimachinery v0.0.0-20261110024958-4608138db381
	k8s.io/apiserver => github.com/openshift/kubernetes/staging/src/k8s.io/apiserver v0.0.0-20261110024958-4608138db381
	k8s.io/client-go => github.com/openshift/kubernetes/staging/src/k8s.io/client-go v0.0.0-20261110024958-4608138db381
	k8s.io/kubernetes => github.com/openshift/kubernetes v1.37.0-alpha.0.0.20261110024958-4608138db381
)
EOF

    # Mock probe: returns 404 for the failing commit, 200 otherwise.
    # shellcheck disable=SC2317 # invoked indirectly via GOPROXY_PROBE_CMD
    _self_test_probe_404() {
        case "$1" in
            *20261110024958-4608138db381*) printf '404' ;;
            *)                             printf '200' ;;
        esac
    }
    # Mock probe: everything is available.
    # shellcheck disable=SC2317 # invoked indirectly via GOPROXY_PROBE_CMD
    _self_test_probe_200() { printf '200'; }

    # Force the master switch ON for every self-test case (A-D): the production
    # default is "false" (opt-in), but the self-test must exercise the check
    # regardless of that default. Exported once here and never unset below.
    export CHECK_GOPROXY_AVAILABILITY=true
    # Deterministic, fast retries for the test.
    export GOPROXY_CHECK_RETRIES=2
    export GOPROXY_CHECK_RETRY_DELAY_SECONDS=0
    export GOPROXY_CHECK_ALL_VERSIONS=false
    export GOPROXY_CHECK_STRICT=false
    export GOPROXY_CHECK_DEADLINE_SECONDS=120
    unset GONOPROXY GOPRIVATE 2>/dev/null || true

    cd "${tmpdir}"

    echo "=== Self-test case A: a missing pseudo-version must fail with remediation ==="
    export GOPROXY_AVAILABILITY_URL="https://proxy.example.test"
    export GOPROXY_PROBE_CMD=_self_test_probe_404
    set +e
    out="$(check_goproxy_availability 2>&1)"
    rc=$?
    set -e
    echo "${out}"
    if (( rc == 0 )); then
        echo "FAIL: case A expected a non-zero exit, got 0"
        failed=1
    fi
    if ! grep -q "github.com/openshift/kubernetes" <<< "${out}"; then
        echo "FAIL: case A output is missing 'github.com/openshift/kubernetes'"
        failed=1
    fi
    # Assert the exact headline pin is reported. This is a form-2 pseudo-version
    # whose timestamp is dot-separated (v1.37.0-alpha.0.0.<ts>-<hash>); asserting
    # the full version string proves the dot-form is detected by default and not
    # merely matched via the staging paths' "github.com/openshift/kubernetes"
    # substring.
    if ! grep -q "github.com/openshift/kubernetes v1.37.0-alpha.0.0.20261110024958-4608138db381" <<< "${out//@/ }"; then
        echo "FAIL: case A did not report the headline pin github.com/openshift/kubernetes v1.37.0-alpha.0.0.20261110024958-4608138db381"
        failed=1
    fi
    # Assert the new remediation guidance is present (stable keywords from the
    # reworded message): the 'go get' command and the word 'tag'.
    if ! grep -q "go get" <<< "${out}"; then
        echo "FAIL: case A output is missing the 'go get' remediation guidance"
        failed=1
    fi
    if ! grep -qw "tag" <<< "${out}"; then
        echo "FAIL: case A output is missing the 'tag' remediation keyword"
        failed=1
    fi

    echo ""
    echo "=== Self-test case B: all versions available must pass ==="
    export GOPROXY_PROBE_CMD=_self_test_probe_200
    set +e
    out="$(check_goproxy_availability 2>&1)"
    rc=$?
    set -e
    echo "${out}"
    if (( rc != 0 )); then
        echo "FAIL: case B expected exit 0, got ${rc}"
        failed=1
    fi

    echo ""
    echo "=== Self-test case C: credentials in the proxy URL must never be logged ==="
    export GOPROXY_AVAILABILITY_URL="https://user:s3cr3t@proxy.example.test"
    export GOPROXY_PROBE_CMD=_self_test_probe_404
    set +e
    out="$(check_goproxy_availability 2>&1)"
    rc=$?
    set -e
    echo "${out}"
    if grep -q "s3cr3t" <<< "${out}"; then
        echo "FAIL: case C leaked the credential 's3cr3t' into the output"
        failed=1
    fi

    echo ""
    echo "=== Self-test case D: a private module must be skipped, not probed ==="
    export GOPROXY_AVAILABILITY_URL="https://proxy.example.test"
    export GOPROXY_PROBE_CMD=_self_test_probe_200
    export GONOPROXY="github.com/example/benign"
    set +e
    out="$(check_goproxy_availability 2>&1)"
    rc=$?
    set -e
    echo "${out}"
    if ! grep -q "Skipping private module(s) matched by GONOPROXY/GOPRIVATE:.*github.com/example/benign" <<< "${out}"; then
        echo "FAIL: case D did not report github.com/example/benign as a skipped private module"
        failed=1
    fi
    if grep -q "github.com/example/benign@" <<< "${out}"; then
        echo "FAIL: case D probed github.com/example/benign instead of skipping it"
        failed=1
    fi
    if (( rc != 0 )); then
        echo "FAIL: case D expected exit 0, got ${rc}"
        failed=1
    fi
    unset GONOPROXY

    # Explicit cleanup (no EXIT handler on purpose; see function header note).
    cd "${origdir}" 2>/dev/null || cd /
    rm -rf "${tmpdir}"

    echo ""
    if (( failed == 0 )); then
        echo "SELF-TEST PASSED"
        return 0
    fi
    echo "SELF-TEST FAILED"
    return 1
}

# Run the embedded self-test when explicitly requested; never in normal CI.
if [[ "${1:-}" == "--self-test" || "${GOPROXY_SELF_TEST:-}" == "1" ]]; then
    if run_self_test; then
        exit 0
    else
        exit 1
    fi
fi

if [[ -f "go.mod" ]]; then
  if ! awk -F'[ .]+' '/^go / && NF < 4 && $3 > 21 {exit 1}' go.mod; then
    # Hermeto fails if the go directive does not have a patch version.
    echo "Error: 'go' directive in go.mod must include a patch version (e.g. go 1.22.0) for go1.22+"
    exit 1
  fi
fi

# Verify pinned Go module pseudo-versions are resolvable on the Go module proxy
# before we attempt the vendor check / a build (ART-26147). Runs only when
# go.mod exists and CHECK_GOPROXY_AVAILABILITY=true.
check_goproxy_availability

if [[ ! -f "go.mod" || ! -d "vendor" ]]; then
    echo "No go.mod vendoring detected in ${PWD}; skipping dependency checks."
    exit 0
else
    echo "Detected go.mod in ${PWD}; verifying vendored dependencies."
fi

if grep -E "github.com/openshift/(api|client-go) v3\.9\.0\+incompatible" go.mod; then
  echo "ERROR: Detected github.com/openshift/api or client-go v3.9.0+incompatible in go.mod"
  echo "Do not use this 'version' of openshift/api or client-go . For complex"
  echo "reasons, this invalid version is a contagion which causes modules"
  echo "which import your code to also import the invalid version."
  echo "Fix:"
  echo "Use an explicit commit in your 'require' statement. You can do"
  echo "this with 'go get github.com/openshift/api@latest' or just specify"
  echo "the import directly. For example, for openshift/api require:"
  echo "        github.com/openshift/api@v0.0.0-20250710004639-926605d3338b"
  echo "In addition, remove any 'replace' statement that may have been in"
  echo "use for the module."
  echo ""
  echo "Unfortunately, this will be necessary until modules you require"
  echo "eliminate their own use of v3.9.0+incompatible import."
  echo ""
  echo "Detail: v3.9.0+incompatible used to be a valid version/tag. However"
  echo "managing @latest via tags was not desired, so the version was deleted."
  echo "Before that deletion, many modules had incorporated the now invalid"
  echo "version. Since the version is greater than v0.0.0 pseudo-versions,"
  echo "go 'upgrades' importing go.mods to use v3.9.0+incompatible and the"
  echo "contagion spreads."
  exit 1
fi

# For debugging
go version

if [[ "${CHECK_MOD_LIST}" == "true" ]]; then
    echo "Checking that all modules can be resolved offline"
    go list -mod=readonly -m all || die_modlist
else
    echo "Skipping go mod list check"
fi

# Allow setting explicit -compat argument for go mod tidy
COMPAT=${COMPAT:-""}

echo "Checking that vendor/ is correct"

echo "Running: go mod tidy $COMPAT"
# shellcheck disable=SC2086 # COMPAT may hold the -compat flag or be empty; intentional word-split
go mod tidy $COMPAT

VENDOR_MODE="mod"
if [[ -f "go.work" && "${GOWORK:-}" != "off" ]]; then
  echo "Detected go workspace; using \"go work vendor\"."
  VENDOR_MODE="work"
fi

echo "Running: go ${VENDOR_MODE} vendor"
go "${VENDOR_MODE}" vendor

# If .gitignore exists, it can inhibit some files from being checked into /vendor. "--ignored"
# ensures that .gitignore is NOT honored during comparison.
CHANGES=$(git status --porcelain --ignored)
if [ -n "$CHANGES" ] ; then
    echo "ERROR: detected vendor inconsistency after 'go mod tidy $COMPAT; go ${VENDOR_MODE} vendor':"
    echo "$CHANGES"
    die_general
fi
