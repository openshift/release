#!/usr/bin/env python3

"""
This script is used to find out missed e2e profiles in upgrade config file.
When we adding new upgrade config files, we can compare e2e config file with upgrade config file, then find out the jobs have not automated in upgrade.

Here is the example to run this script:
```
e2e_yaml="/home/jianl/1_code/release/ci-operator/config/openshift/openshift-tests-private/openshift-openshift-tests-private-release-4.16__amd64-nightly.yaml"
upgrade_yaml="/home/jianl/1_code/release/ci-operator/config/openshift/openshift-tests-private/openshift-openshift-tests-private-release-4.17__amd64-nightly-4.17-upgrade-from-stable-4.16.yaml"
mode='y' # means upgrade path, default is 'y'
jobs # this is a special parameter, when set it or unset upgrade_yaml we will only get jobs from e2e_yaml file

python ci-operator/config/openshift/openshift-tests-private/tools/get_missed_upgrade_jobs.py -e $e2e_yaml -u $upgrade_yaml -j -m "y"
```
"""

import argparse
import re
import yaml 

def get_jobs(yaml_file, mode='y'):
    """Get all jobs from a Prow job config file
    
    Args:
        yaml_file: Absolute path of a Prow job config file
        mode: upgrade mode, 'y' or 'z'
    Returns:
        Job name list
        for example:
            aws-c2s-ipi-disc-priv-fips-f2
            aws-ipi-disc-priv-sts-basecap-none-f14
            aws-ipi-disc-priv-sts-efs-f14
            aws-ipi-disc-priv-sts-ep-fips-f14
    """
    common_skipped_profiles=[
        '-agent',
        'alibaba',
        '-aro',
        '-cloud',
        'day2-64k-pagesize',
        'dedicatedhost',
        'destructive',
        'disasterrecovery',
        'disconnecting',
        'fips-check',
        '-hive',
        'hypershift',
        'longduration',
        '-mco',
        'migrate',
        'migration',
        'netobserv',
        'nokubeadmin',
        '-obo',
        '-ocm',
        '-ota',
        '-regen',
        '-rhel',
        '-rosa',
        'security-profiles-operator',
        '-stress',
        'to-multiarch',
        '-ppc64le',
        '-ui',
        '-winc',
        '-wrs'
    ]
    if mode == 'y':
        common_skipped_profiles.append('tp')
        
    skipped_profiles = '|'.join(common_skipped_profiles)
 
    filtered_jobs = []
    with open(yaml_file, 'r') as file:
        config = yaml.safe_load(file)
        tests = config["tests"] 
    
        for test in tests:
            job = test.get("as")
            
            if "-disc" in job and "-mixarch" in job:
                # it's better to skip the jobs which is a combination of disconnected and mixarch
                # for example: aws-ipi-disc-priv-arm-mixarch-f7
                continue
            
            if test.get("steps", {}).get("env", {}).get("FEATURE_SET", "") == "CustomNoUpgrade":
                continue
            
            match = re.search(skipped_profiles, job) 
            if not match:
                filtered_jobs.append(job)
    return filtered_jobs

def get_missed_profiles(e2e_jobs, upgrade_jobs):
    """
    Get missed e2e jobs in upgrade jobs
    
    Args:
        e2e_jobs: e2e jobs
        upgrade_jobs: existing upgrade jobs
    Returns:
        Job name list, the jobs may not exact correct, need manual check.
        for example:
            vsphere-upi-platform-external-f28
            vsphere-upi-platform-none-f28
            vsphere-upi-zones-f28
    """
    missed_profiles = []
    str_upgrade_jobs = ','.join(upgrade_jobs)
    for job in e2e_jobs:
        e2e_job_name = re.split(r'-f\d+', job)[0]
        if e2e_job_name not in str_upgrade_jobs:
            missed_profiles.append(job)
                
    return missed_profiles

def addtional_check(e2e_yaml_file, upgrade_yaml_file, missed_jobs):
    """
    Additional check on the missed jobs.
    
    Args:
        e2e_yaml_file: e2e yaml file
        upgrade_yaml_file: upgrade yaml file
        missed_jobs: the missed job list which get from get_missed_profiles()
    Returns:
        Job name list, the jobs may not exact correct, need manual check.
        for example:
            vsphere-upi-platform-external-f28
            vsphere-upi-platform-none-f28
            vsphere-upi-zones-f28
    """
    jobs = missed_jobs[:]
            
    minor_version = int(upgrade_yaml_file.split("__")[0].split("openshift-openshift-tests-private-release-")[1].split(".")[1])
    if minor_version > 15:
        for job in jobs:
            if "sdn" in job:
                jobs.remove(job)
    return jobs
    

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Get missed upgrade jobs', 
                                     add_help=True)
    parser.add_argument("-e", "--e2e_yaml", type=str, required=True,
                        help='the path of e2e job file')
    parser.add_argument("-u", "--upgrade_yaml",type=str,
                        help='the path of upgrade job file')
    # upgrade mode, y means y version upgrade, z means z version upgrade
    parser.add_argument("-m", "--mode", default="y", choices=["y", "z"], 
                        help='the upgrade type, y: y stream upgrade, z: z stream upgrade')
    # Only get e2e normal jobs which can be convert to upgrade
    parser.add_argument("-j", "--jobs", action='store_true',
                        help='A switch to indicate if only get e2e jobs')
    
    args = parser.parse_args()
    e2e_yaml = args.e2e_yaml
    upgrade_yaml = args.upgrade_yaml
    mode = args.mode
    
    if args.jobs or not args.upgrade_yaml:
        normal_jobs = get_jobs(e2e_yaml, mode=mode)
        normal_jobs.sort()
        print('\n'.join(normal_jobs))
    else:
        e2e_jobs = get_jobs(e2e_yaml, mode=mode)
        upgrade_jobs = get_jobs(upgrade_yaml, mode=mode)

        missed_jobs = get_missed_profiles(e2e_jobs, upgrade_jobs)
        missed_jobs = addtional_check(e2e_yaml, upgrade_yaml, missed_jobs=missed_jobs)
        missed_jobs.sort()
        print('\n'.join(missed_jobs))
