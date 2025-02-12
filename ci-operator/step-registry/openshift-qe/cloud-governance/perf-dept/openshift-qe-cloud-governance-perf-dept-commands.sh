#!/bin/bash

cat "/secret/perf-dept-creds" > ./perf-creds.sh
ls -la

python3 /usr/local/cloud_governance/main.py

