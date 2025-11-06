"""
Copy CI jobs by FastMCP.

# Preparation
    Read https://modelcontextprotocol.io/quickstart/server#set-up-your-environment to help you install uv
    $ cd ci-operator/config/openshift/openshift-tests-private/tools/mcp_ci
    $ uv init .
    $ uv add "mcp[cli]" httpx PyYAML ruamel_yaml

# Start A Dev Server
    $ uv run mcp dev add_upgrade_jobs_MCP.py

# Create Prow jobs by MCP UI
    1. Go to MCP ui
    2. Click the `Connect` button in the left menu bar
    3. Click the `Tools` button in the middle-top menu bar
    4. Click `List Tools` button
    5. Click the tool `create_CPOU_upgrade_files`
    6. Enter target OCP version, for example `4.21`
    7. Click `Run Tool` button

New CPOU config files will be created, then we just need to run `Make update` in the repo to prepare a PR.

*Note*: Chain upgrade is a little different from other upgrade types, 
        after running the AI tool, you still need to verify if there are missing files.
"""

import glob
import logging
import os
import re
import shutil
import subprocess

from mcp.server.fastmcp import FastMCP
from typing import Tuple

dir_path = os.path.dirname(os.path.realpath(__file__))
DEFAULT_WORKSPACE = dir_path.replace("/tools/mcp_ci/servers", "")

# Create an MCP server
mcp = FastMCP("CI")


def copy_new_file(old_files, is_chain_upgrade=False):
    """copy old upgrade files for new version
    
    Args:
        old_files: The old upgrade files
        is_chain_upgrade: if this is for chain upgrade, then set to True
    Returns:
        A list of new config files
    """
    new_files = []
    
    for f in old_files:
        # split old file name by OCP versions
        # for example, the old file name is: openshift-openshift-tests-private-release-4.19__multi-nightly-4.19-cpou-upgrade-from-4.16.yaml
        # then split it into:
        # - openshift-openshift-tests-private-release-
        # - __multi-nightly-
        # - -cpou-upgrade-from-
        # - .yaml
        split_file_name = re.split(r'4\.\d+', f)
        
        # get all versions from old file name
        match_versions = re.findall(r'4\.\d+', f, re.M|re.I)
        if len(match_versions) != 3:
            continue
        # the first version is the CPOU upgrade's target version
        vers = match_versions[0].split(".")
        target_version = f"4.{int(vers[1])+1}"
        
        # the last version is the upgrade's initial version
        vers = match_versions[-1].split(".")
        initial_version = f"4.{int(vers[1])+1}"
        
        # create new file name
        if is_chain_upgrade:
            # Keep the initial version for chain upgrade
            new_file_name = f"{split_file_name[0]}{target_version}{split_file_name[1]}{target_version}{split_file_name[2]}{match_versions[-1]}.yaml"
        else:
            new_file_name = f"{split_file_name[0]}{target_version}{split_file_name[1]}{target_version}{split_file_name[2]}{initial_version}.yaml"
        
        # skip copy old file when there is new file
        if not os.path.exists(new_file_name):
            shutil.copyfile(f, new_file_name)
            new_files.append(new_file_name)
        else:
            logging.info(f"Config file exists, skip: {new_file_name}")

    return new_files

def get_previous_version_cpou_files(target_version):
    """Get previous version's CPOU config files
    
    Args:
        target_version: the new OCP version which we want to create CPOU jobs for it
    Returns:
        A list of config file paths
    """
    vers = target_version.split(".")
    previous_version =  f"{vers[0]}.{int(vers[1])-1}"
    pattern = f"../../openshift-openshift-tests-private-release-{previous_version}__*-{previous_version}-cpou-upgrade-from-*.yaml"
    files = glob.glob(pattern)
    return list(files)

def get_previous_version_upgrade_files(target_version, is_chain_upgrade=False):
    """Get previous version's upgrade files
    
    Args:
        target_version: the new OCP version which we want to create jobs for it
        is_chain_upgrade: if this is for chain upgrade, then set to True
    Returns:
        A list of config file paths
    """
    vers = target_version.split(".")
    previous_version =  f"{vers[0]}.{int(vers[1])-1}"
    initial_version = f"{vers[0]}.{int(vers[1])-2}"
    pattern = f"../../openshift-openshift-tests-private-release-{previous_version}__*-{previous_version}-upgrade-from-*.yaml"
    files = glob.glob(pattern)
    files = [f for f in files if re.search(r'(amd64|arm64|multi)', f)] # must be OTA team managed files
    if is_chain_upgrade:
        # If this is chain upgrade
        # The initial version must be far less than the target version
        return [f for f in files if not f.endswith(f"{previous_version}.yaml") and not f.endswith(f"{initial_version}.yaml")]
    else:
        return [f for f in files if f.endswith(f"{previous_version}.yaml") or f.endswith(f"{initial_version}.yaml")]
        
def update_upgrade_file_content(files, is_chain_upgrade=False):
    """
    Update file content, especially the versions
    
    Args:
        files: new files
        is_chain_upgrade: if this is for chain upgrade, then set to True
    Returns:
        null
    """
    for f in files:
        with open(f, 'r') as file:
            content = file.read()
            match_versions = re.findall(r'4\.\d+', content, re.M|re.I)
        
            versions = list(set(match_versions))
            versions.sort(reverse=True) # Ensure versions are in descending order
            
            if is_chain_upgrade:
                # For chain upgrade, we keep initial version as is
                # This requres job owners to manual review the jobs
                versions = versions[:-1]
            base_images = content.split("resources:")[0]
            _bottom = content.split("resources:")[1]
            tests = _bottom.split("zz_generated_metadata:")[0]
            zz_generated_metadata = _bottom.split("zz_generated_metadata:")[1]

            for ver in versions:
                major_minor = ver.split(".")
                new_version = f"4.{int(major_minor[1])+1}"
                base_images = base_images.replace("\"" + ver + "\"", "\"" + new_version + "\"")
                zz_generated_metadata = zz_generated_metadata.replace(ver, new_version)
            content = base_images + "resources:" + tests + "zz_generated_metadata:" + zz_generated_metadata

        with open(f, 'w') as file:
            file.write(content)
            
def update_cron_settings(files):
    """
    Update cron settings for a list of files
    
    Args:
        files: a list of files
    Returns:
        True or error message
    """
    update_cron_script = "../update-cron-entries.py"

    for f in files:
        logging.info(f"Upgrade Cron settings for: {f}")
        if not os.path.exists(f):
            return f"File does not exist: {f}"
            
        result = subprocess.run(["python", update_cron_script, '-b', "false", f], capture_output=True, text=True)
        if result.returncode != 0:
            return "Update Cron settings failed: " + result
    
    return True

@mcp.tool()
def create_CPOU_upgrade_files(target_version: str) -> list:
    """Copy prior version's CPOU upgrade files for new version
    
    Args:
        target_version: target OCP version, like 4.21
    
    Returns:
        A list of new files
    """
    files = get_previous_version_cpou_files(target_version)
    new_files = copy_new_file(files)
    update_upgrade_file_content(new_files)
    
    cron_updated = update_cron_settings(new_files)
    if cron_updated != True:
        return [cron_updated]
    
    return new_files

@mcp.tool()
def create_yz_upgrade_files(target_version: str) -> list:
    """Copy prior version's Y stream and Z stream upgrade files for new version
    
    Args:
        target_version: target OCP version, like 4.21
    
    Returns:
        A list of new files
    """
    files = get_previous_version_upgrade_files(target_version)
    new_files = copy_new_file(files)
    update_upgrade_file_content(new_files)
    
    cron_updated = update_cron_settings(new_files)
    if cron_updated != True:
        return [cron_updated]
    
    return new_files

@mcp.tool()
def create_chain_upgrade_files(target_version: str) -> list:
    """Copy prior version's chain upgrade files for new version
    
    *Note*: Chain upgrade is a little different from other upgrade types,
        after running the AI tool, you still need to verify if there are missing files.
    
    Args:
        target_version: target OCP version, like 4.21
    
    Returns:
        A list of new files
    """
    files = get_previous_version_upgrade_files(target_version, is_chain_upgrade=True)
    new_files = copy_new_file(files, is_chain_upgrade=True)
    update_upgrade_file_content(new_files, is_chain_upgrade=True)
    
    cron_updated = update_cron_settings(new_files)
    if cron_updated != True:
        return [cron_updated]
    
    # remove old chain upgrade files
    for f in files:
        os.remove(f)
    return new_files
    
@mcp.tool()
async def execute_bash(cmd: str) -> Tuple[str, str]:
    """
    Run a bash command in the workspace.

    Args:
        cmd: The shell command to execute.

    Returns:
        A tuple (stdout, stderr) from the command execution.
    """
    process = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        shell=True,
        cwd=DEFAULT_WORKSPACE
    )
    stdout, stderr = process.communicate()
    return stdout, stderr

@mcp.resource("resource://{version}")
async def get_resource(version: str) -> list:
    """Get upgrade files for the specified OCP version"""
    vers = version.split(".")
    target_version =  f"{vers[0]}.{int(vers[1])}"
    pattern = f"../../openshift-openshift-tests-private-release-{target_version}__*-upgrade-from-*.yaml"
    files = glob.glob(pattern)
    files = [f for f in files if re.search(r'(amd64|arm64|multi)', f)] 
    return files


if __name__ == "__main__":
    mcp.run(transport="stdio")