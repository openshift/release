#!/usr/bin/python

import re

import oc_common


def main():
    j = oc_common.connect_to_jenkins()
    descRegex = re.compile("_openshift/(.*)/(.*)")
    for descr in j.credentials.keys():
        match = descRegex.match(descr)
        if match:
            print("{}/{}".format(match.group(1), match.group(2)))


if __name__ == "__main__":
    main()
