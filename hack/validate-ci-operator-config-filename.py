#!/usr/bin/env python

'''
This script validates the ci-operator's config filename, to be
in $org-$repo-$branch.yaml format. Assuming that the folders tree will be
$config_dir/$org/$repo/
'''

import sys
import os
from argparse import ArgumentParser


def parse_args():
    parser = ArgumentParser()
    parser.add_argument("--config-dir", default="ci-operator/config",
                        help="root dir of ci-operator configs")
    return parser.parse_args()


def main():
    args = parse_args()
    errors = []

    if not os.path.isdir(args.config_dir):
        errors.append("[ERROR] {} directory doesn't exist.".format(args.config_dir))

    for root, _, files in os.walk(args.config_dir):
        for name in files:
            if name.endswith(".yaml"):
                root_path = root.replace(args.config_dir, "")
                filename = os.path.splitext(os.path.basename(name))[0]
                try:
                    org = root_path.split("/")[1]
                    repo = root_path.split("/")[2]
                except IndexError:
                    print(
                        "[ERROR] Folder structure is not in $config_dir/$org/$repo/ format for file {}/{}".format(root_path, name))
                    exit(1)

                branch = filename.replace(org + "-" + repo + "-", "")
                expected_filename = org + "-" + repo + "-" + branch
                if not filename == expected_filename:
                    errors.append(
                        "[ERROR] File {} should be in {}-{}-$branch.yaml format".format(filename, org, repo))
    if len(errors) > 0:
        print(errors)
        sys.exit(1)


if __name__ == '__main__':
    main()
