#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VENV_PATH="$SCRIPT_DIR/gcp-secret-manager/gcp-secrets-venv"
GCLOUD_CONFIG_PATH="$SCRIPT_DIR/gcp-secret-manager/.secret-manager-gcloud"

(
    if [ ! -d "$VENV_PATH" ]; then
        python3 -m venv "$VENV_PATH"
        source "$VENV_PATH/bin/activate"
        pip install --upgrade pip
        if ! pip install --quiet -r "$SCRIPT_DIR/gcp-secret-manager/requirements.txt"; then
            rm -rf "$VENV_PATH"
            echo "" >&2
            echo "Failed to install dependencies. This can happen when your Python version" >&2
            echo "($(python3 --version)) does not yet have compatible packages available." >&2
            echo "If so, install an older Python (e.g. brew install python@3.13) and ensure" >&2
            echo "it appears first in your PATH, then try again." >&2
            exit 1
        fi
    else
        source "$VENV_PATH/bin/activate"
    fi

    mkdir -p "$GCLOUD_CONFIG_PATH"

    # CLOUDSDK_CONFIG: use an isolated gcloud config directory so login, ADC, and all
    # gcloud state are separate from the user's ~/.config/gcloud/.
    # GOOGLE_CLOUD_QUOTA_PROJECT: attribute API usage/billing to openshift-ci-secrets.
    exec env \
        CLOUDSDK_CONFIG="$GCLOUD_CONFIG_PATH" \
        GOOGLE_CLOUD_QUOTA_PROJECT="openshift-ci-secrets" \
        python3 "$SCRIPT_DIR/gcp-secret-manager/main.py" "$@"
)
