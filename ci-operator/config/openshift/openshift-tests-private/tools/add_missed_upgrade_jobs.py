#!/usr/bin/env python3

"""
This script is used to add missed e2e profiles in upgrade config file.
***NOTE: 
after running this script, you still need to
1. check the new config file manually, for example, you need to update the test chain step.
2. run 'make update'
***

Here is the example to run this script:
```
e2e_yaml=ci-operator/config/openshift/openshift-tests-private/openshift-openshift-tests-private-release-4.13__multi-nightly.yaml
upgrade_yaml=ci-operator/config/openshift/openshift-tests-private/openshift-openshift-tests-private-release-4.13__multi-nightly-4.13-upgrade-from-stable-4.13.yaml
mode='y' # means upgrade path, default is 'y'

python ci-operator/config/openshift/openshift-tests-private/tools/add_missed_upgrade_jobs.py -e $e2e_yaml -u $upgrade_yaml -m "y"
```
"""

import argparse
import yaml

from get_missed_upgrade_jobs import *

def get_e2e_job(e2e_yaml, job_name):
    """Get e2e job object by job name from a e2e job config file
    
    Args:
        e2e_yaml: Absolute path of a e2e job config file
        job_name: the missed e2e job name
    Returns:
        a yaml object of e2e job
    """
    with open(e2e_yaml, 'r') as file:
        e2e_config = yaml.safe_load(file)
        tests = e2e_config["tests"]
        for test in tests:
            if test['as'] == job_name:
                return test
        else:
            return None
        
def upsert_jobs(upgrade_tests, new_job_obj):
    """insert and update upgrade job list
    
    Args:
        upgrade_tests: Existing upgrade jobs
        new_job_obj: the job yaml object
    Returns:
        None
    """
    to_be_added_job_name = new_job_obj['as']
    print(f"to_be_added_job_name: {to_be_added_job_name}")
    for i in range(len(upgrade_tests)):
        current_job = upgrade_tests[i]['as']
        if current_job > to_be_added_job_name:
            upgrade_tests.insert(i, new_job_obj)
            break

def save_config_file(yaml_file, yaml_obj):
    print(f"Save config: {yaml_file}")
    with open(yaml_file, 'w') as file:
        yaml.dump(yaml_obj, file)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Save missed upgrade jobs', 
                                     add_help=True)
    parser.add_argument("-e", "--e2e_yaml", type=str, required=True,
                        help='the path of e2e job file')
    parser.add_argument("-u", "--upgrade_yaml",type=str,
                        help='the path of upgrade job file')
    # upgrade mode, y means y version upgrade, z means z version upgrade
    parser.add_argument("-m", "--mode", default="y", choices=["y", "z"], 
                        help='the upgrade type, y: y stream upgrade, z: z stream upgrade')
    
    args = parser.parse_args()
    e2e_yaml = args.e2e_yaml
    upgrade_yaml = args.upgrade_yaml
    mode = args.mode
    
    e2e_jobs = get_jobs(e2e_yaml, mode=mode)
    upgrade_jobs = get_jobs(upgrade_yaml, mode=mode)

    missed_jobs = get_missed_profiles(e2e_jobs, upgrade_jobs)
    missed_jobs.sort()
    print("Missed jobs: ")
    print(missed_jobs)
    
    with open(upgrade_yaml, 'r') as file:
        upgrade_config = yaml.safe_load(file)
        tests = upgrade_config["tests"]
    
    for missed_job in missed_jobs:
        job = get_e2e_job(e2e_yaml, missed_job)
        upsert_jobs(tests, job)
        
    upgrade_config["tests"] = tests
    
    save_config_file(upgrade_yaml, upgrade_config)
