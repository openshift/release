#!/bin/bash
set -e
set -o pipefail

date
echo "This is test case"
echo ${MY_TEST_VAR}
ls -l /var/run/temp-vault
cat /var/run/temp-vault/temp_secret
nmap -Pn -p 22 10.46.55.212
