#!/usr/bin/env python3

"""
Builds on Konflux do not work if the go version listed in go.mod files is not of format 1.23.2 (major.minor.patch).
"""

import os
import yaml
import requests
import subprocess
from pathlib import Path


# Get current working directory
current_dir = os.getcwd()
print(f"Current directory: {current_dir}")

# Change directory
new_dir = "/home/prow/go/src/github.com/openshift/aws-encryption-provider"  # Replace with the actual path
os.chdir(new_dir)

# Verify the change
current_dir = os.getcwd()
print(f"Current directory: {current_dir}")

process = subprocess.run(['ls', '-la'], capture_output=True, text=True)
print(process.stdout)

process = subprocess.run(['git', 'branch'], capture_output=True, text=True)
print(process.stdout)

def get_paths():
    ocp_build_data_file_name = os.environ["OCP_BUILD_DATA_FILENAME"]  # Eg: azure-file-csi-driver-operator.yml
    ocp_version = os.environ["OCP_VERSION"]  # Eg: openshift-4.19

    if not (ocp_build_data_file_name and ocp_version):
        raise Exception("Both OCP_BUILD_DATA_FILENAME and OCP_VERSION need to be specified")

    url = f"https://raw.githubusercontent.com/openshift-eng/ocp-build-data/refs/heads/{ocp_version}/images/{ocp_build_data_file_name}"

    response = requests.get(url)

    if response.status_code != 200:
        raise Exception(f"ERROR: Status code for request {url} is {response.status_code}")

    data = yaml.safe_load(response.text)

    go_mod_entries = data.get("cachito", {}).get("packages", {}).get("gomod", [])
    print(f"gomod entries: {go_mod_entries}")

    custom_paths = [Path(os.getcwd()).joinpath("go.mod")]
    for entry in go_mod_entries:
        for key, value in entry.items():
            if key == "path":
                custom_paths.append(Path(os.getcwd()).joinpath(f"{value}/go.mod"))
    return custom_paths




# Check the current directory by default.
# But also check the custom paths defined in ocp-build-data, eg: https://github.com/openshift-eng/ocp-build-data/blob/openshift-4.20/images/ose-etcd.yml#L5-L16
paths = list(set(get_paths()))
gomod_paths = [path for path in paths if path.exists()]

if gomod_paths:
    print(f"Checking go.mod files present in paths {gomod_paths}")
    for gomod_path in gomod_paths:
        with open(gomod_path.absolute(), "r") as file:
            lines = file.readlines()
            for line in lines:
                if line.startswith("go"):
                    line_content = line.strip()
                    version = line_content.split(" ")[-1]
                    if len(version.split(".")) == 2:
                        raise Exception(f"go version should be of format 1.23.2 (major.minor.patch). Found: {line_content}")
else:
    print(f"No go.mod files found in {paths}")
