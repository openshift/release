"""
This script is used to add missed e2e profiles in upgrade config file.
***NOTE: 
after running this script, you still need to
1. check the new config file manually, for example, you need to update the test chain step.
2. you need to run 'make update'
***

Here is the example to run this script:
```
e2e_yaml=ci-operator/config/openshift/openshift-tests-private/openshift-openshift-tests-private-release-4.13__multi-nightly.yaml
upgrade_yaml=ci-operator/config/openshift/openshift-tests-private/openshift-openshift-tests-private-release-4.13__multi-nightly-4.13-upgrade-from-stable-4.13.yaml

python ci-operator/config/openshift/openshift-tests-private/tools/add_missed_jobs.py $e2e_yaml $upgrade_yaml
```
"""

import sys
import yaml 

from get_missed_upgrade_jobs import *

def get_e2e_job(e2e_yaml, job_name):
    """Get e2e job by job name from a e2e job config file
    
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
        
def add_job(upgrade_tests, missed_test):
    """Add e2e job to upgrade job list
    
    Args:
        upgrade_tests: a list of test object
        missed_test: the missed e2e job object
    """
    missed_job = missed_test['as']
    for i in range(len(upgrade_tests)):
        current_job = upgrade_tests[i]['as']
        # new job will be added alphabetically
        if current_job > missed_job:
            upgrade_tests.insert(i, missed_test)
            break

def save_upgrade_config(upgrade_yaml, yaml_obj):
    """Save upgrade job config file
    
    Args:
        upgrade_yaml: upgrade job config file path
        yaml_obj: the final yaml object
    """
    print(f"Save config: {upgrade_yaml}")
    with open(upgrade_yaml, 'w') as file:
        yaml.dump(yaml_obj, file)
    

if __name__ == "__main__":
    args = sys.argv
    if len(args) != 3:
        raise Exception("Missing e2e config file or missing upgrade config file or given extra parameters")
    
    e2e_jobs = get_jobs(args[1])
    upgrade_jobs = get_jobs(args[2])

    missed_jobs = get_missed_profiles(e2e_jobs, upgrade_jobs)
    missed_jobs.sort()
    
    with open(args[2], 'r') as file:
        upgrade_config = yaml.safe_load(file)
        tests = upgrade_config["tests"]
    
    for missed_job in missed_jobs:
        job = get_e2e_job(args[1], missed_job.split(":")[1].strip())
        add_job(tests, job)
        
    upgrade_config["tests"] = tests
    
    save_upgrade_config(args[2], upgrade_config)