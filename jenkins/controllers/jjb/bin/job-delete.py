#!/usr/bin/python

from __future__ import print_function
import sys
from subprocess import call

import jobs_common

def main(argv):
    if len(argv)==0:
        print('No arguments passed. Please specify a namespace, and name')
    elif len(argv)>=2:
        delete_job(argv[0], argv[1])

def delete_job(namespace, name):
    call(["jenkins-jobs", "delete", name])
    jobs_common.delete_from_known_names(namespace, name)

if __name__ == "__main__":
    main(sys.argv[1:])
