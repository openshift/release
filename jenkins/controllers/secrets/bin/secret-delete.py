#!/usr/bin/python

import sys
import os
import re

from oc_requester import OpenShiftRequester
from jenkinsapi.jenkins import Jenkins 
import oc_common

def main(argv):
    if len(argv)==0:
        print('No arguments passed. Please specify a namespace and name')
    elif len(argv)>=2:
        delete_secret(argv[0], argv[1])

def delete_secret(namespace, name):
    j = oc_common.connect_to_jenkins()
    creds = j.credentials
    name = "_openshift/{}/{}".format(namespace, name)
    if name in creds:
        print("deleting secret {} from Jenkins".format(name))
        del creds[name]

if __name__ == "__main__":
    main(sys.argv[1:])
