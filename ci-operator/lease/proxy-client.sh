# Internal use only: download jq if it is not already available.
#
# Result:
#   Return 0, export a new PATH env variable having the jq download directory as first entry.
#   Return 1 and print an error message otherwise.
function _lease__ensure_jq() {
    if command -v jq &>/dev/null; then
        return 0
    fi

    local response_body="$(mktemp --tmpdir=/tmp ensure-jq-XXXXX)" || {
        printf 'Failed to create temp file\n'
        return 1
    }

    local response="$(curl --connect-timeout 300 --max-time 600 \
      --retry 5 --retry-delay 10 --retry-all-errors \
      --no-progress-meter -sL \
      -o "$response_body" \
      --write-out '%{response_code}' \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      https://api.github.com/repos/jqlang/jq/releases)" || {
        printf 'Failed to determine jq releases from %s\n%s\n' \
          'https://api.github.com/repos/jqlang/jq/releases' \
          "$response"
        rm -f "$response_body" &>/dev/null
        return 1
    }

    grep -qP '2\d{2}' <<<"$response" || {
        printf 'Failed to determine jq releases from %s\n%s\n' \
          'https://api.github.com/repos/jqlang/jq/releases' \
          "$response"
        cat "$response_body"
        rm -f "$response_body" &>/dev/null
        return 1
    }

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

    local jq_download_link=''
    if ! jq_download_link=$(grep -P "browser_download_url.+linux\-$jq_arch" "$response_body" | grep -Po '\: \"\K[^\"]+' | head -1); then
        printf 'Failed to determine jq download link: %s\n' "$jq_download_link"
        rm -f "$response_body" &>/dev/null
        return 1
    fi

    local download_dir="$(mktemp --tmpdir=/tmp -d jq-XXXXX)" || {
        printf 'Failed to create the jq download directory: %s\n' "$download_dir"
        rm -f "$response_body" &>/dev/null
        return 1
    }

    local jq_bin="${download_dir}/jq"
    response=$(curl --connect-timeout 300 --max-time 600 --no-progress-meter \
      --retry 5 --retry-delay 10 --retry-all-errors \
      -L --write-out '%{response_code}' "${jq_download_link}" -o "$jq_bin") || {
        printf 'Failed to download jq at %s: %s\n' "$jq_download_link" "$response"
        rm -f "$response_body" &>/dev/null
        return 1
    }

    grep -qP '2\d{2}' <<<"$response" || {
        printf 'Failed to download jq at %s: %s\n' "$jq_download_link" "$response"
        rm -f "$response_body" &>/dev/null
        return 1
    }

    chmod +x "$jq_bin" || {
        printf 'Failed to grant exec permission to %s\n' "$jq_bin"
        rm -f "$response_body" &>/dev/null
        return 1
    }

    if ! "$jq_bin" --version &>/dev/null; then
        printf 'Downloaded jq is not executable or invalid\n'
        rm -f "$response_body" &>/dev/null
        return 1
    fi

    export PATH="$download_dir:$PATH"
    rm -f "$response_body" &>/dev/null
    return 0
}
export -f _lease__ensure_jq

# Acquire `--count` leases of type `--type`, store them in a file a return it.
# If `--scope=test` is passed, the leases are also saved into `${SHARED_DIR}/leases` so 
# they can be released by calling `lease__release --scope=test` from another test step.
#
# Options:
#   -t|--type:  Lease resource type. Required.
#   -c|--count: Number of leases to acquire. Optional, default to 1.
#   --scope: If `test` save the acquired lease names into`${SHARED_DIR}/leases`. Otherwise save
#     them in a temporary file.
#   --jitter: Delay the execution by a random value chosen from the range [0, ${jitter}]. 
#     Only minutes and seconds are allowed, but not a combination of them: 10s, 15m.
#
# Environment:
#   LEASE_PROXY_SERVER_URL: Lease proxy server URL in this form: `http://lease.proxy`.
#     Optional, execute in dry run mode and always succeed if it is not set.
#   SHARED_DIR: A directory that persists across multiple multi-stage steps.
#
# Result:
#   Return 0 if the operation succeeds and print file name in which the leases have been saved.
#   Return 1 and print an error message otherwise.
#   Return 2 and print an error message if the lease type does not exist.
function lease__acquire() {
    local type=''
    local count='1'
    local scope='test'
    local jitter=''
    local jitter_defined=0

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
            --scope=*)
                scope="${1#*=}"
                shift
                ;;
            --jitter=*)
                jitter_defined=1
                jitter="${1#*=}"
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

    local jitter_value='0'
    local jitter_unit=''
    if [[ $jitter_defined -eq 1 ]]; then
        if [[ "$jitter" =~ ^([1-9][[:digit:]]*)(m|s)$ ]]; then
            jitter_value="${BASH_REMATCH[1]}"
            jitter_unit="${BASH_REMATCH[2]}"
            if [[ "$jitter_unit" == "m" ]]; then
                jitter_value=$(( jitter_value * 60 ))
            fi
        else
            printf "jitter parameter is invalid\n"
            return 1
        fi
    fi

    if [ "$scope" != "step" -a "$scope" != "test" ]; then
        printf "scope parameter is invalid\n"
        return 1
    fi

    if [ -z "${LEASE_PROXY_SERVER_URL:-}" ]; then
        printf 'LEASE_PROXY_SERVER_URL-not-set-dry-run-mode\n'
        return 0
    fi

    _lease__ensure_jq || return 1

    local response_body="$(mktemp --tmpdir=/tmp lease-acquire-XXXXX)" || {
        printf 'Failed to create temp file\n'
        return 1
    }

    if (( $jitter_value > 0 )); then
        local max=$(( $jitter_value + 1 ))
        local start_delay=$(( $RANDOM % $max ))
        sleep "${start_delay}" || {
            printf 'Failed to delay the execution\n'
            return 1
        }
    fi

    local ec=0
    local response=$(curl --no-progress-meter -X POST -o "$response_body" \
      --retry 5 --retry-delay 10 --retry-all-errors \
      -G --data-urlencode "type=$type" --data-urlencode "count=$count" \
      --write-out '%{response_code}' \
      "${LEASE_PROXY_SERVER_URL}/lease/acquire") || ec=$?

    if [ $ec -eq 0 ]; then
        case "$response" in
            404)
                printf "Failed to acquire \"%s\": it does not exist\n" "$type"
                rm -f "$response_body" &>/dev/null
                return 2
                ;;
            2*)
                local names=''
                if ! names=$(jq -r '.names[]' "$response_body"); then
                    printf 'Failed to parse the response\n'
                    rm -f "$response_body" &>/dev/null
                    return 1
                fi

                if [ -z "$names" ]; then
                    rm -f "$response_body" &>/dev/null
                    return 0
                fi

                if [ "$scope" == "test" ]; then
                    if [ -z "${SHARED_DIR:-}" ]; then
                        printf '$SHARED_DIR is empty\n'
                        return 1
                    fi

                    local test_leases="${SHARED_DIR}/leases"
                    # Append a newline at the end because we might want to append multiple
                    # times to the same file and we want prevent two names being on the
                    # same line.
                    if ! printf '%s\n' "$names" >>"$test_leases"; then
                        printf "Failed to store lease names in \"%s\"\n" "$test_leases"
                        return 1
                    fi
                fi

                local lease_handle=$(mktemp --tmpdir=/tmp "${type}-XXXXX") || {
                    printf 'Failed to create lease handle\n'
                    return 1
                }

                touch "${lease_handle}.lock" || {
                    printf 'Failed to create %s\n' "${lease_handle}.lock"
                    return 1
                }

                if ! printf '%s' "$names" >"$lease_handle"; then
                    printf "Failed to create lease handle \"%s\"\n" "$lease_handle"
                    return 1
                fi

                printf '%s' "$lease_handle"
                rm -f "$response_body" &>/dev/null
                return 0
                ;;
            *)
                printf 'Unexpected response code %s while acquiring lease "%s"\n' "$response" "$type"
                cat "$response_body"
                rm -f "$response_body"
                return 1
                ;;
        esac
    fi

    printf '%s\n' "$response"
    rm -f "$response_body" &>/dev/null
    return 1
}
export -f lease__acquire

# Release leases, waiting `--delay` if it has been passed.
# When `--name=a,b,c` is passed as argument, release the leases a, b and c.
# When `--handle=/tmp/leases` is passed as argument, lock the file `/tmp/leases.lock` that is assumed to exist already,
#   release all the leases in `/tmp/leases` and then delete it. Used in this way, `lease__release` is idempotent
#   because, once the `--handle` file has been deleted, the function will simply do nothing.
#
# Options:
#   -n|--names: A comma separated list of lease names to release.
#   --delay: Sleep before releasing anything.
#   --handle: The file that contains the leases to be released.
#   --scope: When `test` is passed, release all the leases that have been acquired by `lease__acquire --scope=test`.
#
# Environment:
#   LEASE_PROXY_SERVER_URL: Lease proxy server URL in this form: `http://lease.proxy`.
#     Optional, execute in dry run mode and always succeed if it is not set.
#
# Result:
#   Return 0 only if the operation succeeds and print the leases that have been released.
#   Return 1 and print an error message otherwise.
function lease__release() {
    local names=''
    local handle=''
    local handle_defined=0
    local delay=''
    local scope=''

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--names)
                names="$2"
                shift 2
                ;;
            --names=*)
                names="${1#*=}"
                shift
                ;;
            --handle=*)
                handle_defined=1
                handle="${1#*=}"
                shift
                ;;
            --delay=*)
                delay="${1#*=}"
                shift
                ;;
            --scope=*)
                scope="${1#*=}"
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    local exclusive_params=0
    [[ -n "$names" ]] && ((++exclusive_params))
    [ $handle_defined -eq 1 ] && ((++exclusive_params))
    [[ -n "$scope" ]] && ((++exclusive_params))
    if ((exclusive_params > 1)); then
        printf "Parameters --names, --handle, and --scope are mutually exclusive\n"
        return 1
    fi

    if ((exclusive_params == 0)); then
        printf "One of --names, --handle, or --scope is required\n"
        return 1
    fi

    if [ -z "${LEASE_PROXY_SERVER_URL:-}" ]; then
        printf 'LEASE_PROXY_SERVER_URL not set, dry run mode: it would release \"%s\"\n' "$names"
        return 0
    fi

    if [ ! -z "$delay" ]; then
        sleep "$delay" || {
            printf 'Failed to sleep %s\n' "$delay"
            return 1
        }
    fi

    if [ "$scope" == "test" ]; then
        _lease__release_test_scoped
        return
    fi

    if [ $handle_defined -eq 1 ]; then
        if [[ -z "$handle" ]]; then
            return 0
        fi
        LEASE_HANDLE="$handle" flock "${handle}.lock" -c _lease__release_from_handle || {
            printf 'Failed to release leases on critical path\n'
            return 1
        }
        return 0
    fi

    if [ -z "$names" ]; then
        printf "lease names are required\n"
        return 1
    fi

    local response_body="$(mktemp --tmpdir=/tmp lease-release-XXXXX)" || {
        printf 'Failed to create temp file\n'
        return 1
    }

    local request_body=$(jq -cR '{names: split(",")}' <<<"$names") || {
        printf 'Failed to compose the request body: %s' "$request_body"
        return 1
    }

    local ec=0
    local response=$(curl --no-progress-meter -X POST -o "$response_body" \
      --retry 5 --retry-delay 10 --retry-all-errors \
      -H "Content-Type: application/json" -d "$request_body" --write-out '%{response_code}' \
      "${LEASE_PROXY_SERVER_URL}/lease/release") || ec=$?

    local result=1
    if [ $ec -eq 0 ]; then
        case "$response" in
            2*)
                result=0
                ;;
            *)
                printf 'Unexpected response code %s while releasing leases "%s"\n' "$response" "$names"
                cat "$response_body"
                rm -f "$response_body"
                return 1
                ;;
        esac
    else
        printf '%s\n' "$response"
        rm -f "$response_body" &>/dev/null
        return 1
    fi

    printf '%s\n' "$names released"
    rm -f "$response_body" &>/dev/null
    return $result
}
export -f lease__release

# Return 0 if the current cluster profile set is eligible to acquire an install lease, 1 otherwise.
function lease__install_lease_eligible() {
    [[ "${CLUSTER_PROFILE_SET_NAME:-}" =~ ^openshift-org-.+$ ]]
}
export -f lease__install_lease_eligible

function lease__cat() {
    local handle=''
    local format='plain'
    local pretty=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --handle=*)
                handle="${1#*=}"
                shift
                ;;
            --format=*)
                format="${1#*=}"
                shift
                ;;
            --pretty-format=*)
                pretty=1
                format="${1#*=}"
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    if [[ -z "$handle" || ! -f "$handle" ]]; then
        return 0
    fi

    case "$format" in
        csv)
            local names=''
            if ! names=$(tr '\n' ',' <"$handle"); then
                printf "Failed to read lease names from \"%s\": %s\n" "$handle" "$names"
                return 1
            fi

            # Remove trailing commas, if any.
            while [[ "$names" == *, ]]; do
                names="${names%,}"
            done

            printf '%s' "$names"
            [[ $pretty -eq 1 ]] && printf '\n'
            ;;
        plain)
            cat "$handle"
            ;;
        *)
            printf 'Invalid format %s\n' "$format"
            return 1
            ;;
    esac
}
export -f lease__cat

# Internal use only: release all leases stored into `$SHARED_DIR/leases`.
function _lease__release_test_scoped() {
    if [ -z "${SHARED_DIR:-}" ]; then
        printf '$SHARED_DIR is empty\n'
        return 1
    fi

    local lease_names_path="${SHARED_DIR}/leases"

    if [ ! -f "$lease_names_path" ]; then
        return 0
    fi

    local names=$(lease__cat --handle="$lease_names_path" --format=csv) || {
        printf 'Failed to read leases from %s\n' "$lease_names_path"
        return 1
    }

    if [ -z "$names" ]; then
        return 0
    fi

    local ec=0
    lease__release --names="$names" || ec=$?
    if [ $ec -ne 0 ]; then
        return $ec
    fi

    if ! printf '' >"$lease_names_path"; then
        printf "Failed to clean \"%s\"\n" "$lease_names_path"
        return 1
    fi

    return 0
}
export -f _lease__release_test_scoped

# Internal use only: release the leases stored into the file passed as first argument.
function _lease__release_from_handle() {
    local handle="$LEASE_HANDLE"

    if [ ! -f "$handle" ]; then
        return 0
    fi

    local leases=$(lease__cat --handle="$handle" --format=csv) || {
        printf 'Failed to read leases from %s\n' "$handle"
        return 1
    }

    if [ -z "$leases" ]; then
        return 0
    fi

    lease__release --names="$leases" || return 1

    if ! rm "$handle"; then
        printf 'Failed to remove %s\n' "$handle"
        return 1
    fi

    return 0
}
export -f _lease__release_from_handle

