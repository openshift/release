#!/usr/bin/env python

import getopt
import re
import yaml
import sys
import os
import subprocess
from datetime import datetime

def usage():
    print("""
Usage: python %s [--backup [yes|no]] [--force [yes|no]] file1 file2 ...

This tool will go through all the test items in the specified job yaml files, call generate-cron-entry.sh to set each job's cron entiries in batch.

By default, --backup is enabled, it will backup the editing job yaml for your comparation before your final submit.

If you set the --force parameter, it is propagated to the generation bash script, to also consider test configs disabled by default (for example, the *-baremetal-*).

# Prerequisite:
Download https://raw.githubusercontent.com/openshift/release/master/ci-operator/config/openshift/openshift-tests-private/tools/generate-cron-entry.sh into $PATH, and make it executable.
""" % (sys.argv[0]))


def get_cli_opts():
    backup_opt = "yes"
    force_generation = False
    options, args = getopt.getopt(sys.argv[1:], "fhb:", ["force", "help", "backup="])
    for opt, value in options:
        if opt in ("-h", "--help"):
            usage()
        if opt in ("-b", "--backup"):
            backup_opt = value
        if opt in ("-f", "--force"):
            force_generation = True

    return backup_opt, force_generation, args


if __name__ == "__main__":
    backup_flag, force_generation, target_file_list = get_cli_opts()
    profile_list = []

    if len(target_file_list) == 0:
        target_file_list = []
    
    zstream_profiles = {'4.12': {'e2e': {'amd64': ['aws-c2s-ipi-disconnected-private-p2-f14',
                                                    'gcp-ipi-proxy-private-p2-f14'],
                                        'arm64': ['baremetalds-ipi-ovn-ipv4-p2-f14']},
                                'upgrade': {'amd64': ['azure-ipi-fips-p2-f14'],
                                            'arm64': ['aws-ipi-proxy-cco-manual-sts-p2-f28']}}}
    
    for target_file in target_file_list:
        if "stable" not in target_file:
            print("skip updating %s" % (target_file))
            continue
        release_version = target_file.split("release-")[1].split("__")[0]
        if release_version not in zstream_profiles.keys():
            print("Do not support updating %s" % (target_file))
            continue
        if "upgrade" in target_file:
            major_version = release_version.split(".")[0]
            minor_version = release_version.split(".")[1]
            if minor_version != "0":
                release_version_pre = major_version[0]+"."+str(int(minor_version)-1)
                if release_version_pre not in target_file:
                    print("skip updating %s" % (target_file))
                    continue
            else:
                print("skip updating %s" % (target_file))
                continue
            print("Updating %s" % (target_file))
            if "amd64" in target_file:
                profile_list = zstream_profiles[release_version]["upgrade"]["amd64"]
            if "arm64" in target_file:
                profile_list = zstream_profiles[release_version]["upgrade"]["arm64"]
        elif "stable.yaml" in target_file:
            print("Updating %s" % (target_file))
            if "amd64" in target_file:
                profile_list = zstream_profiles[release_version]["e2e"]["amd64"]
            if "arm64" in target_file:
                profile_list = zstream_profiles[release_version]["e2e"]["arm64"]
        print("Updating %s" % (profile_list))

        with open(target_file, 'r') as file:
            all_data = yaml.safe_load(file)
        file.close()

        all_tests_list = all_data['tests']
        new_tests_list = []
        index = 0
        for test in all_tests_list:
            test_name = test['as']
            if test_name in profile_list:
                print("updating test job - %s" % test_name)
                test['cron'] = "0 "+str(index)+" * * 4"
                index = index +1
            new_tests_list.append(test)

        all_data['tests'] = new_tests_list

        if backup_flag == "yes":
            backup_file = "%s.%s" % (target_file, datetime.now().strftime("%Y%m%d%H%M%S"))
            os.rename(target_file, backup_file)

        with open(target_file, 'w') as file:
            yaml.dump(all_data, file, default_flow_style=False)
        file.close()
