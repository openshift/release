#!/bin/bash

# Set script directory to always work relative to this file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VENV_PATH="$SCRIPT_DIR/gcp-secret-manager/gcp-secrets-venv"

# Create virtual environment if it doesn't exist
if [ ! -d "$VENV_PATH" ]; then
    python3 -m venv "$VENV_PATH" #creates a directory (gcp-secrets-venv) that contains a self-contained Python environment with its own python binary and package manager (pip).
    source "$VENV_PATH/bin/activate"
    pip install --upgrade pip
    pip install --quiet -r "$SCRIPT_DIR/gcp-secret-manager/requirements.txt"
else
    source "$VENV_PATH/bin/activate"
fi

# Forward arguments to the Python script
python3 "$SCRIPT_DIR/gcp-secret-manager/main.py" "$@"
