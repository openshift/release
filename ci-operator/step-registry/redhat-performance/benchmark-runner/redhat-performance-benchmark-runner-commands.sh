#!/bin/bash

set -eu

python3.14 /benchmark_runner/main/main.py
rc=$?
echo "benchmark-runner exit code: $rc"
exit $rc
