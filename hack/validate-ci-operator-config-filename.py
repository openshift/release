#!/usr/bin/env python3

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
        errors.append(f"ERROR: {args.config_dir} directory doesn't exist.")

    for root, _, files in os.walk(args.config_dir):
        for name in files:
            if name.endswith(".yml"):
                print(f"ERROR: Only .yaml extensions are allowed, not .yml as in {root_path}/{name}")
                sys.exit(1)
            if name.endswith(".yaml"):
                root_path = os.path.relpath(root, args.config_dir)
                filename, _ = os.path.splitext(name)
                try:
                    org, repo = os.path.split(root_path)
                except ValueError:
                    print(f"ERROR: Folder structure is not in $config_dir/$org/$repo/ format for file {root_path}/{name}")
                    sys.exit(1)

                if not filename.startswith(f"{org}-{repo}-"):
                    errors.append(f"ERROR: File '{args.config_dir}/{root}/{name}' name should have '{org}-{repo}-$branch.yaml' format")

    if errors:
        print("\n".join(errors))
        sys.exit(1)


if __name__ == '__main__':
    main()
