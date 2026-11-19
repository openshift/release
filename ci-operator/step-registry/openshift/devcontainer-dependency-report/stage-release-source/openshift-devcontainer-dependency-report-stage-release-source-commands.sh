#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

release_root=/go/src/github.com/openshift/release
manifest_relative=hack/devcontainer-dependency-report-source-files.txt
manifest="${release_root}/${manifest_relative}"
snapshot="${SHARED_DIR}/devcontainer-dependency-release-source"

mapfile -t files < "${manifest}"
if (( ${#files[@]} == 0 )); then
  echo "release source manifest is empty" >&2
  exit 1
fi
for file in "${files[@]}"; do
  case "${file}" in
    ""|/*|..|../*|*/..|*/../*)
      echo "release source manifest has unsafe path: ${file}" >&2
      exit 1
      ;;
  esac
  if [[ ! -f "${release_root}/${file}" ]]; then
    echo "release source file does not exist: ${file}" >&2
    exit 1
  fi
done

mkdir -p "${snapshot}"
git -C "${release_root}" rev-parse HEAD > "${snapshot}/REVISION"
git -C "${release_root}" diff --quiet HEAD -- "${manifest_relative}" "${files[@]}"
(
  cd "${release_root}"
  cp --parents -- "${files[@]}" "${snapshot}"
  sha256sum -- "${files[@]}" > "${snapshot}/SHA256SUMS"
)
