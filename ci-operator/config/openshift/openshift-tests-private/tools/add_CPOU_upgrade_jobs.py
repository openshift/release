#!/usr/bin/env python3

"""
This script is used to create new CPOU upgrade jobs.
***NOTE: 
after running this script, you still need to
1. update cron settings
2. run 'make update'
***

Here is the example to run this script:
```
python ci-operator/config/openshift/openshift-tests-private/tools/add_CPOU_upgrade_jobs.py -v 4.20
```
"""

import argparse
import glob
import os
import re
import shutil


relative_path = "ci-operator/config/openshift/openshift-tests-private"

def get_previous_version_cpou_files(currentVersion):
    """Get previous version's CPOU config file
    
    Args:
        currentVersion: the new OCP version which we want to create CPOU jobs
    Returns:
        A list of config file paths
    """
    vers = currentVersion.split(".")
    previousVersion =  f"{vers[0]}.{int(vers[1])-1}"
    pattern = f"{relative_path}/openshift-openshift-tests-private-release-{previousVersion}__*{previousVersion}-cpou-upgrade-from-*.yaml"
    files = glob.glob(pattern)
    return list(files)
        
def copy_new_file(oldFiles):
    """copy old files for new version
    
    Args:
        oldFiles: The old CPOU files
    Returns:
        A list of new config files
    """
    newfiles = []
    
    for f in oldFiles:
        # split old file name by OCP versions
        # for example, the old file name is: openshift-openshift-tests-private-release-4.19__multi-nightly-4.19-cpou-upgrade-from-4.16.yaml
        # then split it into:
        # - openshift-openshift-tests-private-release-
        # - __multi-nightly-
        # - -cpou-upgrade-from-4.16.yaml
        splitFileName = re.split(r'4\.\d+', f)
        
        # get all versions from old file name
        matchVersions = re.findall(r'4\.\d+', f, re.M|re.I)
        if len(matchVersions) != 3:
            continue
        # the first version is the CPOU upgrade's target version
        vers = matchVersions[0].split(".")
        targetVersion = f"4.{int(vers[1])+1}"
        
        # the last version is the CPOU upgrade's initial version
        vers = matchVersions[-1].split(".")
        initialVersion = f"4.{int(vers[1])+1}"
        
        # create new file name
        newFileName = f"{splitFileName[0]}{targetVersion}{splitFileName[1]}{targetVersion}{splitFileName[2]}{initialVersion}.yaml"
        
        # skip copy old file when there is new file
        if not os.path.exists(newFileName):
            shutil.copyfile(f, newFileName)
            newfiles.append(newFileName)

    return newfiles

def update_file_content(files):
    """
    Update file content, especially the versions
    
    Args:
        files: new files
    Returns:
        null
    """
    for f in files:
        with open(f, 'r') as file:
            content = file.read()
            matchVersions = re.findall(r'4\.\d+', content, re.M|re.I)
        
            versions = list(set(matchVersions))
            versions.sort(reverse=True) # Ensure versions are in descending order
            for ver in versions:
                major_minor = ver.split(".")
                newVersion = f"4.{int(major_minor[1])+1}"
                content = content.replace(ver, newVersion)
        
        with open(f, 'w') as file:
            file.write(content)
            

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Copy CPOU upgrade jobs for new release', 
                                     add_help=True)
    parser.add_argument("-v", "--version", type=str, required=True,
                        help='New OCP version')
    
    args = parser.parse_args()
    version = args.version
    files = get_previous_version_cpou_files(version)
    newFiles = copy_new_file(files)
    update_file_content(newFiles)