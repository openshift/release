#!/usr/bin/env python

import getopt
import yaml
import sys
import os
import subprocess
from datetime import datetime

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
    print ("""
Usage: python %s [--backup [yes|no]] file1 file2 ...

This tool will go through all the test items in the specified job yaml files, call generate-cron-entry.sh to set each job's cron entiries in batch.

By default, --backup is enabled, it will backup the editing job yaml for your comparation before your final submit.

# Presiquisite:
Download https://raw.githubusercontent.com/openshift/release/master/ci-operator/config/openshift/openshift-tests-private/tools/generate-cron-entry.sh into $PATH, and make it executable.
""" % (sys.argv[0]))

def get_cli_opts():
    backup_opt = "yes"
    options, args = getopt.getopt(sys.argv[1:], "hb:", ["help", "backup="])
    for opt, value in options:
        if opt in ("-h", "--help"):
            usage()
        if opt in ("-b", "--backup"):
            backup_opt = value

    return backup_opt, args

if __name__ == "__main__":
    backup_flag, target_file_list = get_cli_opts()

    if len(target_file_list) == 0:
        usage()
        sys.exit(-1)

    for target_file in target_file_list:
        print("Updating %s" %(target_file))
    
        with open(target_file, 'r') as file:
            all_data = yaml.safe_load(file)
        file.close()
    
        all_tests_list = all_data['tests']
        new_tests_list = []
        for test in all_tests_list:
            test_name = test['as']
            print("updating test job - %s" %(test_name))
            cron_output = shell("generate-cron-entry.sh %s %s" %(test_name, target_file))["out"]
            cron_entry = cron_output.split("cron:")[-1].strip()
            print(cron_entry)
            test['cron'] = cron_entry
            new_tests_list.append(test)
        
        all_data['tests'] = new_tests_list
        
        if backup_flag == "yes":
            backup_file = "%s.%s" %(target_file, datetime.now().strftime("%Y%m%d%H%M%S"))
            os.rename(target_file, backup_file)
    
        with open(target_file, 'w') as file:
            yaml.dump(all_data, file)
        file.close()
