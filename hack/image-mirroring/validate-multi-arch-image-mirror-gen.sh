#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail



function check_diff() {
    if ! diff -bur "${base_dir}/$1" "${workdir}/$1" >"${workdir}/diff"; then
    cat <<EOF
ERROR: To update the the multi-arch image mirroring run the following and
ERROR: commit the result:

ERROR: $ make multi-arch-gen

ERROR: The following differences were found:

EOF
    cat "${workdir}/diff"
    exit 1
    fi
}


NAMESPACES_FILE="clusters/app.ci/multi-arch/namespaces.yaml"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

base_dir="${1:-}"
if [[ ! -d "${base_dir}" ]]; then
    echo "Expected a single argument: a path to a directory with release repo layout"
    exit 1
fi

cp -r "${base_dir}" "${workdir}"

if ! ./hack/image-mirroring/supplemental_ci_images_mirror_gen.py; then
    echo "multi-arch supplemental image mirroring generation failed"
    exit 1
fi

# Check generated namespaces
check_diff ${NAMESPACES_FILE}

for folder in $(find core-services/ -iname "image-mirroring-*");do
    check_diff $folder
done
