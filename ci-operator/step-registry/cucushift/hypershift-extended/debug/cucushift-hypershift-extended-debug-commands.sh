#!/bin/bash

set -xeuo pipefail

cat /proc/1/cgroup
env

sleep "$KEEP_DURATION"