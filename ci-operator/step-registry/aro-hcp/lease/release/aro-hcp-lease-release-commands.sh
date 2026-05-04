#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

readonly ARO_HCP_SLOT_MANAGER_DEFAULT_GIT_REMOTE="https://github.com/roivaz/ARO-HCP"

run_slot_manager() {
    local subcommand temp_dir repo_dir go_path go_cache go_tmp_dir rc
    subcommand="$1"
    shift

    if [[ -z "${ARO_HCP_SLOT_MANAGER_GIT_REF:-}" ]]; then
        ./test/aro-hcp-tests slot-manager "${subcommand}" "$@"
        return
    fi

    if [[ ! -w "${PWD}" ]]; then
        printf 'Current working directory is not writable: %s\n' "${PWD}" >&2
        return 1
    fi

    if ! temp_dir=$(mktemp -d "${PWD}/.aro-hcp-slot-manager.XXXXXX"); then
        printf 'Failed to create workspace-local temp dir for slot-manager override\n' >&2
        return 1
    fi

    repo_dir="${temp_dir}/ARO-HCP"
    printf 'Using slot-manager override ref %s from %s\n' "${ARO_HCP_SLOT_MANAGER_GIT_REF}" "${ARO_HCP_SLOT_MANAGER_DEFAULT_GIT_REMOTE}" >&2

    if ! git init --quiet "${repo_dir}" ||
        ! git -C "${repo_dir}" remote add origin "${ARO_HCP_SLOT_MANAGER_DEFAULT_GIT_REMOTE}" ||
        ! git -C "${repo_dir}" fetch --depth=1 origin "${ARO_HCP_SLOT_MANAGER_GIT_REF}" ||
        ! git -C "${repo_dir}" checkout --detach --quiet FETCH_HEAD; then
        chmod -R u+w "${temp_dir}" 2>/dev/null || true
        rm -rf "${temp_dir}"
        return 1
    fi

    go_path="${temp_dir}/go"
    go_cache="${temp_dir}/gocache"
    go_tmp_dir="${temp_dir}/gotmp"
    if ! mkdir -p "${go_path}" "${go_cache}" "${go_tmp_dir}"; then
        chmod -R u+w "${temp_dir}" 2>/dev/null || true
        rm -rf "${temp_dir}"
        return 1
    fi

    if (
        cd "${repo_dir}"
        export GOPATH="${go_path}"
        export GOCACHE="${go_cache}"
        export GOMODCACHE="${go_path}/pkg/mod"
        export GOTMPDIR="${go_tmp_dir}"
        export TMPDIR="${go_tmp_dir}"
        export TMP="${go_tmp_dir}"
        export TEMP="${go_tmp_dir}"
        case " ${GOFLAGS:-} " in
            *" -modcacherw "*) ;;
            *) export GOFLAGS="${GOFLAGS:+${GOFLAGS} }-modcacherw" ;;
        esac
        go run ./test/cmd/aro-hcp-tests slot-manager "${subcommand}" "$@"
    ); then
        rc=0
    else
        rc=$?
    fi

    chmod -R u+w "${temp_dir}" 2>/dev/null || true
    rm -rf "${temp_dir}"
    return "${rc}"
}

run_slot_manager release --shared-dir "${SHARED_DIR}"
