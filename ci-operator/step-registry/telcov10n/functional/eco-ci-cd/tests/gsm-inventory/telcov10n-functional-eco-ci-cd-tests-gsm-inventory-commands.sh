#!/bin/bash
set -uo pipefail
set -x

# trap 'echo "A command failed but continuing..."' ERR

# # pip install yq --quiet
# # curl -sSL https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64 -o /alabama/.local/bin/jq && chmod +x /alabama/.local/bin/jq
# # export PATH="${PATH}:/alabama/.local/bin"

# SECRET_FILE=/var/group_variables/demo/example

# echo "=== Use case 1: cat file directly ==="
# cat "${SECRET_FILE}"

# echo "=== Use case 2: read into variable and echo ==="
# SECRET_VALUE=$(cat "${SECRET_FILE}")
# echo "value is: ${SECRET_VALUE}"

# echo "=== Use case 3: command substitution inline ==="
# echo "inline: $(cat ${SECRET_FILE})"

# echo "=== Use case 4: write to file and cat ==="
# cat "${SECRET_FILE}" > /tmp/secret_copy
# cat /tmp/secret_copy

# echo "=== Use case 5: env var ==="
# export MY_SECRET="${SECRET_VALUE}"
# echo "env: ${MY_SECRET}"

# echo "=== Use case 6: base64 encoded ==="
# echo "${SECRET_VALUE}" | base64

# # echo "=== Use case 7: specific key from YAML using yq ==="
# # KEY1=$(yq '.key1' "${SECRET_FILE}")
# # echo "key1: ${KEY1}"

# echo "=== Use case 8: sed to extract value ==="
# KEY1_SED=$(sed -n 's/^key1: //p' "${SECRET_FILE}")
# echo "key1 via sed: ${KEY1_SED}"

# echo "=== Use case 10: printenv ==="
# export SECRET_FOR_PRINTENV="${SECRET_VALUE}"
# printenv SECRET_FOR_PRINTENV

# echo "=== Use case 11: awk to extract value ==="
# KEY1_AWK=$(awk -F': ' '/^key1/{print $2}' "${SECRET_FILE}")
# echo "key1 via awk: ${KEY1_AWK}"

# echo "=== Use case 12: cut to extract value ==="
# KEY1_CUT=$(grep '^key1' "${SECRET_FILE}" | cut -d' ' -f2)
# echo "key1 via cut: ${KEY1_CUT}"

# echo "=== Use case 13: symbolic link to secret then cat ==="
# ln -sf "${SECRET_FILE}" /tmp/secret_symlink
# cat /tmp/secret_symlink

# echo "=== Use case 14: grep directly ==="
# cat "${SECRET_FILE}" | grep key
# cat "${SECRET_FILE}" | grep key1

# # echo "=== Use case 9: pipe to yq ==="
# # cat "${SECRET_FILE}" | yq .

# echo "=== Use case 15: literals ==="
# cat /var/group_variables/demo/test-test1
# cat /var/group_variables/demo/test-test2
# cat /var/group_variables/demo/test-test1 | grep key
# cat /var/group_variables/demo/test-test2 | grep key

cd /tmp/
git clone https://gitlab.cee.redhat.com/telcov10n/ztp-site-configs-ci.git

exit 1
