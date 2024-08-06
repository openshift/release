"""
This script is used to find out missed e2e profiles in upgrade config file.
When we adding new upgrade config files, we can compare e2e config file with upgrade config file, then find out the jobs have not automated in upgrade.

Here is the example to run this script:
```
e2e_yaml="/home/jianl/1_code/release/ci-operator/config/openshift/openshift-tests-private/openshift-openshift-tests-private-release-4.16__amd64-nightly.yaml"
upgrade_yaml="/home/jianl/1_code/release/ci-operator/config/openshift/openshift-tests-private/openshift-openshift-tests-private-release-4.17__amd64-nightly-4.17-upgrade-from-stable-4.16.yaml"
mode='y' # default is 'y'

python ci-operator/config/openshift/openshift-tests-private/tools/get_missed_upgrade_jobs.py $e2e_yaml $upgrade_yaml $mode
```
"""

import re
import subprocess
import sys

def get_jobs(yaml_file):
    """Get all jobs from a Prow job config file
    
    Args:
        yaml_file: Absolute path of a Prow job config file
    Returns:
        Job name list
        for example:
            - as: vsphere-upi-encrypt-f28-destructive
            - as: vsphere-upi-platform-external-f28
            - as: vsphere-upi-platform-external-f28-destructive
            - as: vsphere-upi-platform-none-f28
            - as: vsphere-upi-platform-none-f28-destructive
            - as: vsphere-upi-zones-f28
    """
    cmd=f"grep -e '- as:' {yaml_file}"
    process = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out, err = process.communicate()
    str_out = out.decode("utf-8")
    return str_out.split("\n")

def get_missed_profiles(e2e_jobs, upgrade_jobs, mode='y'):
    """
    Get missed e2e jobs in upgrade jobs
    
    Args:
        e2e_jobs: e2e jobs
        upgrade_jobs: existing upgrade jobs
        mode: upgrade mode, 'y' or 'z'
    Returns:
        Job name list, the jobs may not exact correct, need manual check.
        for example:
            - as: vsphere-upi-platform-external-f28
            - as: vsphere-upi-platform-none-f28
            - as: vsphere-upi-zones-f28
    """
    missed_profiles = []
    common_skipped_profiles=[
        'agent',
        'alibaba',
        'aro',
        'cloud',
        'day2-64k-pagesize',
        'destructive',
        'disasterrecovery',
        'disconnecting',
        'fips-check',
        'hive',
        'hypershift',
        'longduration',
        'mco',
        'netobserv',
        'nokubeadmin',
        'ocm',
        'regen',
        'rhel',
        'rosa',
        'security-profiles-operator',
        'stress',
        'to-multiarch',
        'ui',
        'winc',
        'wrs'
    ]
    if mode == 'y':
        common_skipped_profiles.append('tp')
        skipped_profiles = '|'.join(common_skipped_profiles)
    elif mode == 'z':
        skipped_profiles = '|'.join(common_skipped_profiles)
    else:
        print("Unknown upgrade mode, available mode are 'y' and 'z'")
        exit()
    str_upgrade_jobs = ','.join(upgrade_jobs)
    for job in e2e_jobs:
        match = re.search(skipped_profiles, job) 
        if not match:
            e2e_job_name = job.replace("- as: ", '')
            e2e_job_name = re.split(r'-f\d+', e2e_job_name)[0]
    
            if e2e_job_name not in str_upgrade_jobs:
                missed_profiles.append(job)
                
    return missed_profiles


if __name__ == "__main__":
    args = sys.argv
    if len(args) < 3:
        raise Exception("Missing e2e config file or upgrade config file")
    
    e2e_jobs = get_jobs(args[1])
    upgrade_jobs = get_jobs(args[2])
    
    # upgrade mode, y means y version upgrade, z means z version upgrade
    mode = args[3] if len(args) == 4 else 'y'

    missed_jobs = get_missed_profiles(e2e_jobs, upgrade_jobs, mode=mode)
    missed_jobs.sort()
    print('\n'.join(missed_jobs))