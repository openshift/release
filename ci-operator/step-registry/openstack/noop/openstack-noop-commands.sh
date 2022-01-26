#!/usr/bin/env bash

set -Eeuo pipefail

echo 'This step does nothing. Have a nice day!'
rpm -qa
printenv
which go || true
sleep 3600
