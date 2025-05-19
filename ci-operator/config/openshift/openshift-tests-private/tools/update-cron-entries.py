#!/usr/bin/env python

import getopt
import yaml
import sys
import os
import subprocess
from datetime import datetime

#import yaml
#To avoid yaml.load change doulbe-quotes values to sigle-quote, use ruamel.yaml module instead of yaml
# Run any of below commands to install ruamel:
#   yum install python3-ruamel-yaml.x86_64
#   pip install ruamel_yaml
from ruamel.yaml import YAML
yaml=YAML()
yaml.default_flow_style = False
yaml.preserve_quotes = True

def shell(cmd, debug=False, env_=dict(os.environ)):
    """
    Args:
        cmd (string): command to execute
        debug (bool, optional): print cmd before executing. Defaults to False.
        env_ (dict, optional): environment variables. Defaults to dict(os.environ).

    Returns:
        dict[str, str, int]: {"out": stdout, "err": stderr, "rc": return code}
    """
    if debug:
        print("Command: %s" % cmd)
    result = {"err": "", "out": "", "rc": -1}
    try:
        res = subprocess.Popen(cmd, shell=True, stderr=subprocess.PIPE, stdout=subprocess.PIPE, env=env_)
        cmd_stdout, cmd_stderr = res.communicate()
        if sys.version_info[0] < 3:
            result["err"] = cmd_stderr.strip()
            result["out"] = cmd_stdout.strip()
        else:
            result["err"] = cmd_stderr.strip().decode()
            result["out"] = cmd_stdout.strip().decode()
        result["rc"] = res.returncode
    except Exception as ex:
        print("Error: %s" % str(ex))
    return result


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

    if len(target_file_list) == 0:
        usage()
        sys.exit(-1)

    cron_prefix = "cron:"
    for target_file in target_file_list:
        print("Updating %s" % (target_file))

        with open(target_file, 'r') as file:
            #all_data = yaml.safe_load(file)
            all_data = yaml.load(file)
        file.close()

        all_tests_list = all_data['tests']
        new_tests_list = []
        for test in all_tests_list:
            test_name = test['as']
            print("updating test job - %s" % test_name)
            command = "generate-cron-entry.sh %s %s %s" % (test_name, os.path.basename(target_file),
                                                           "--force" if force_generation else "")
            cron_output = shell(command)["out"]
            if cron_output.startswith(cron_prefix):
                cron_entry = cron_output.split(cron_prefix)[-1].strip()
                print(cron_entry)
                test['cron'] = cron_entry
            else:
                print("Did not find expected '%s' prefix from the output of '%s', next..." % (cron_prefix, command))
            new_tests_list.append(test)

        all_data['tests'] = new_tests_list

        if backup_flag == "yes":
            backup_file = "%s.%s" % (target_file, datetime.now().strftime("%Y%m%d%H%M%S"))
            os.rename(target_file, backup_file)

        with open(target_file, 'w') as file:
            yaml.dump(all_data, file)
        file.close()
