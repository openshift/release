#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "******** Checking Claude works..."
claude -p "Tell me a hilarious joke about CI."

echo "******** Checking ai-helpers is installed..."
claude -p "/hello-world:echo I am a stick."
