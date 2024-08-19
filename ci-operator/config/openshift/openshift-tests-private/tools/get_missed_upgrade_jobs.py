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
import yaml 

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
        '-agent',
        'alibaba',
        '-aro',
        '-cloud',
        'day2-64k-pagesize',
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
            - as: vsphere-upi-platform-external-f28
            - as: vsphere-upi-platform-none-f28
            - as: vsphere-upi-zones-f28
    """
    jobs = []
    if "multi" in upgrade_yaml_file:
        for job in missed_jobs:
            if "-disc" in job and "-mixarch" in job:
                # it's better to skip the jobs which is a combination of disconnected and mixarch
                # for example: aws-ipi-disc-priv-arm-mixarch-f7
                continue
            
            jobs.append(job)
    else:
        jobs = [x for x in missed_jobs]
    

    with open(e2e_yaml_file, 'r') as file:
        e2e_config = yaml.safe_load(file)
        tests = e2e_config["tests"]
    
    for job in jobs:
        e2e_job_name = job.replace("- as: ", '')
        filtered_job = list(filter(lambda x: x.get('as') == e2e_job_name, tests))[0]
        steps = filtered_job.get("steps")
        if steps.get("env") and \
            steps.get("env").get("FEATURE_SET") and \
            steps.get("env").get("FEATURE_SET") == "CustomNoUpgrade":
            jobs.remove(job)
            
    minor_version = int(upgrade_yaml_file.split("__")[0].split("openshift-openshift-tests-private-release-")[1].split(".")[1])
    if minor_version > 15:
        for job in jobs:
            if "sdn" in job:
                jobs.remove(job)
    return jobs
    

if __name__ == "__main__":
    args = sys.argv
    if len(args) < 3:
        raise Exception("Missing e2e config file or upgrade config file")
    e2e_yaml = args[1]
    upgrade_yaml = args[2]
    
    e2e_jobs = get_jobs(e2e_yaml)
    upgrade_jobs = get_jobs(upgrade_yaml)
    
    # upgrade mode, y means y version upgrade, z means z version upgrade
    mode = args[3] if len(args) == 4 else 'y'

    missed_jobs = get_missed_profiles(e2e_jobs, upgrade_jobs, mode=mode)
    missed_jobs = addtional_check(e2e_yaml, upgrade_yaml, missed_jobs=missed_jobs)
    missed_jobs.sort()
    print('\n'.join(missed_jobs))