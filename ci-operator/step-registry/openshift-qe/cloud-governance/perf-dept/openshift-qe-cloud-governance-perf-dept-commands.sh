#!/bin/bash

cat "/secret/perf-dept-creds" > ./perf-creds.sh
# chmod 777 ./perf-creds.sh
ls -la
# source ./perf-creds.sh

python3 /usr/local/cloud_governance/main.py

