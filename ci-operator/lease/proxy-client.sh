# Download jq if it is not already available.
#
# Result:
#   Return 0, export a new PATH env variable having the jq download directory as first entry.
#   Return 1 and print an error message otherwise.
function lease__ensure_jq() {
    if command -v jq &>/dev/null; then
        return 0
    fi

    local ec=0
    local response_body="$(mktemp --tmpdir=/tmp ensure-jq-XXXXX)" || ec=$?
    if [ $ec -ne 0 ]; then
        printf 'Failed to create temp file: %s\n' "$response_body"
        return 1
    fi

    local response="$(curl --no-progress-meter -sL \
      -o "$response_body" \
      --write-out '%{response_code}' \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      https://api.github.com/repos/jqlang/jq/releases)" || ec=$? 
    if [ $ec -ne 0 ]; then
        printf 'Failed to determine jq releases from %s\n%s\n' \
          'https://api.github.com/repos/jqlang/jq/releases' \
          "$response"
        rm -f "$response_body" &>/dev/null
        return 1
    fi

    grep -qP '2\d{2}' <<<"$response" || ec=$?
    if [ $ec -ne 0 ]; then
        printf 'Failed to determine jq releases from %s\n%s\n' \
          'https://api.github.com/repos/jqlang/jq/releases' \
          "$response"
        cat "$response_body"
        rm -f "$response_body" &>/dev/null
        return 1
    fi

    local jq_arch=''
    case $(uname -m) in
        x86_64)
            jq_arch='amd64'
            ;;
        aarch64)
            jq_arch='arm64'
            ;;
        s390x)
            jq_arch='s390x'
            ;;
        *)
            printf 'jq release not available for the architecture: %s\n' "$(uname -m)"
            rm -f "$response_body" &>/dev/null
            return 1
            ;;
    esac

    local jq_download_link=$(grep -P "browser_download_url.+linux\-$jq_arch" "$response_body" | grep -Po '\: \"\K[^\"]+' | head -1) || ec=$?
    if [ $ec -ne 0 -o -z "$jq_download_link" ]; then
        printf 'Failed to determine jq download link: %s\n' "$jq_download_link"
        rm -f "$response_body" &>/dev/null
        return 1
    fi

    local download_dir="$(mktemp --tmpdir=/tmp -d jq-XXXXX)" || ec=$?
    if [ $ec -ne 0 ]; then
        printf 'Failed to create the jq download directory: %s\n' "$download_dir"
        rm -f "$response_body" &>/dev/null
        return 1
    fi

    local jq_bin="${download_dir}/jq"
    response=$(curl --no-progress-meter -L --write-out '%{response_code}' "${jq_download_link}" -o "$jq_bin") || ec=$?
    if [ $ec -ne 0 ]; then
        printf 'Failed to download jq at %s: %s\n' "$jq_download_link" "$response"
        rm -f "$response_body" &>/dev/null
        return 1
    fi

    grep -qP '2\d{2}' <<<"$response" || ec=$?
    if [ $ec -ne 0 ]; then
        printf 'Failed to download jq at %s: %s\n' "$jq_download_link" "$response"
        rm -f "$response_body" &>/dev/null
        return 1
    fi

    chmod +x "$jq_bin" || ec=$?
    if [ $ec -ne 0 ]; then
        printf 'Failed to grant exex permission to %s\n' "$jq_bin"
        rm -f "$response_body" &>/dev/null
        return 1
    fi

    if ! "$jq_bin" --version &>/dev/null; then
        printf 'Downloaded jq is not executable or invalid\n'
        rm -f "$response_body" &>/dev/null
        return 1
    fi

    export PATH="$download_dir:$PATH"
    rm -f "$response_body" &>/dev/null
    return 0
}

# Acquire a lease from the lease proxy server.
#
# Options:
#   -t|--type:  Lease resource type. Required.
#   -c|--count: Number of leases to acquire. Optional, default to 1.
#
# Environment:
#   LEASE_PROXY_SERVER_URL: Lease proxy server URL in this form: `http://lease.proxy`.
#     Optional, execute in dry run mode and always succeed if it is not set.
#
# Result:
#   Return 0 if the operation succeeds and print the lease names that have been acquired,
#     separated each other by a single space.
#   Return 1 and print an error message otherwise.
#   Return 2 and print an error message if the lease type does not exist.
function lease__acquire() {
    local type=''
    local count='1'
    local ec=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--type)
                type="$2"
                shift 2
                ;;
            --type=*)
                type="${1#*=}"
                shift
                ;;
            -c|--count)
                count="$2"
                shift 2
                ;;
            --count=*)
                count="${1#*=}"
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    if [ -z "$type" ]; then
        printf "resource type parameter is invalid\n"
        return 1
    fi

    if [[ ! "$count" =~ ^[[:digit:]]+$ ]]; then
        printf "count parameter is invalid\n"
        return 1
    fi

    if [ -z "$LEASE_PROXY_SERVER_URL" ]; then
        printf 'LEASE_PROXY_SERVER_URL-not-set-dry-run-mode\n'
        return 0
    fi

    local jq_out=$(lease__ensure_jq 2>&1) || ec=$?
    if [ $ec -ne 0 ]; then
        printf '%s\n' "$jq_out"
        return 1
    fi

    local response_body="$(mktemp --tmpdir=/tmp lease-acquire-XXXXX)" || ec=$?
    if [ $ec -ne 0 ]; then
        printf 'Failed to create temp file: %s\n' "$response_body"
        return 1
    fi

    local response=$(curl --no-progress-meter -X POST -o "$response_body" \
      --write-out '%{response_code}' \
      "${LEASE_PROXY_SERVER_URL}/lease/acquire?type=${type}&count=${count}") || ec=$?

    if [ $ec -eq 0 ]; then
        case "$response" in
            404)
                printf "Failed to acquire \"%s\": it does not exist\n" "$type"
                rm -f "$response_body" &>/dev/null
                return 2
                ;;
            2*)
                jq -r '.names[]' "$response_body"
                rm -f "$response_body" &>/dev/null
                return 0
                ;;
        esac
    else
        printf '%s\n' "$response"
        rm -f "$response_body" &>/dev/null
        return 1
    fi

    cat "$response_body"
    rm -f "$response_body" &>/dev/null
    return 1
}

# Release a lease.
#
# Options:
#   -n|--name: Lease name to release.
#
# Environment:
#   LEASE_PROXY_SERVER_URL: Lease proxy server URL in this form: `http://lease.proxy`.
#     Optional, execute in dry run mode and always succeed if it is not set.
#
# Result:
#   Return 0 only if the operation succeeds.
#   Return 1 and print an error message otherwise.
function lease__release() {
    local name=''
    local ec=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--name)
                name="$2"
                shift 2
                ;;
            --name=*)
                name="${1#*=}"
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    if [ -z "$name" ]; then
        printf "resource name is required\n"
        return 1
    fi

    if [ -z "$LEASE_PROXY_SERVER_URL" ]; then
        printf 'LEASE_PROXY_SERVER_URL not set, dry run mode: it would release \"%s\"\n' "$name"
        return 0
    fi

    local response_body="$(mktemp --tmpdir=/tmp lease-release-XXXXX)" || ec=$?
    if [ $ec -ne 0 ]; then
        printf 'Failed to create temp file: %s\n' "$response_body"
        return 1
    fi

    local response=$(curl --no-progress-meter -X POST -o "$response_body" \
      --write-out '%{response_code}' \
      "${LEASE_PROXY_SERVER_URL}/lease/release?name=${name}") || ec=$?

    local result=1
    if [ $ec -eq 0 ]; then
        case "$response" in
            200)
                result=0
                ;;
        esac
    else
        printf '%s\n' "$response"
        rm -f "$response_body" &>/dev/null
        return 1
    fi

    cat "$response_body"
    rm -f "$response_body" &>/dev/null
    return $result
}
