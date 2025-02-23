#!/bin/bash
set -e
set -o pipefail

process_inventory() {
    local directory="$1"
    local dest_file="$2"

    if [ -z "$directory" ]; then
        echo "Usage: process_inventory <directory> <dest_file>"
        return 1
    fi

    if [ ! -d "$directory" ]; then
        echo "Error: '$directory' is not a valid directory"
        return 1
    fi

    for filename in $(find $directory -type f); do
        echo "$(basename ${filename})": "$(cat $filename)"
    done > $dest_file

    echo "Processing complete. Check ${dest_file}"
}

mkdir /eco-ci-cd/inventories/ocp-deployment/group_vars

find /var/group_variables/ -mindepth 1 -type d | while read -r dir; do
    echo "Process group inventory file: ${dir}"
    process_inventory $dir /eco-ci-cd/inventories/ocp-deployment/group_vars/$(basename ${dir})
done

ls -l /eco-ci-cd/inventories/ocp-deployment/group_vars/
ansible --version
