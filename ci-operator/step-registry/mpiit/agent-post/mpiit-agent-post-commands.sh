#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

exec /opt/entrypoint.sh
