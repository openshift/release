#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

: "${RELEASE_IMAGE_LATEST:?Release controller must supply the published payload}"
work_dir=$(mktemp -d)
trap 'rm -rf "${work_dir}"' EXIT
export UV_CACHE_DIR="${work_dir}/uv-cache"
export UV_PROJECT_ENVIRONMENT="${work_dir}/venv"
touch "${work_dir}/artcd.toml"

args=()
case "${INSTALLER_TRIGGER_DRY_RUN}" in
  true) args+=(--dry-run) ;;
  false) ;;
  *) echo 'INSTALLER_TRIGGER_DRY_RUN must be true or false' >&2; exit 2 ;;
esac

uv run --locked --no-dev artcd --config "${work_dir}/artcd.toml" "${args[@]}" \
  trigger-installer-build --payload "${RELEASE_IMAGE_LATEST}" \
  --kubeconfig /var/run/installer-build-trigger/kubeconfig
