#!/usr/bin/env python3

import os
import yaml
import requests
from pathlib import Path

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

    paths = []
    for entry in go_mod_entries:
        for key, value in entry.items():
            if key == "path":
                paths.append(Path(os.getcwd()).joinpath(f"{value}/go.mod"))
    return paths


gomod_paths = ["."] + get_paths()
gomod_paths = list(set(gomod_paths))
print(f"Found paths to check: {gomod_paths}")

for gomod_path in gomod_paths:
    if gomod_path.exists():
        print(f"go mod file exists at: {gomod_path.absolute()}")
        with open(gomod_path, "r") as file:
            lines = file.readlines()

            for line in lines:
                if line.startswith("go"):
                    line_content = line.strip()
                    version = line_content.split(" ")[-1]

                    if len(version.split(".")) == 2:
                        raise Exception(f"go version should be of format 1.23.2 (major.minor.patch). Found: {line_content}")
        print("No issues found")
    else:
        print(f"go mod file not found at path {gomod_path.absolute()}")
