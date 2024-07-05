#!/usr/bin/env python3
"""This script handles turning on acknowledge-critical-fixes-only for a
single branch on a single repository."""
import copy
import sys
import os
import yaml

def split_out_branch(repo, branch_to_split, revert=False):
    """Splits out branch from a prow config"""
    script_dir = os.path.dirname(os.path.realpath(__file__))
    yaml_file = os.path.join(script_dir,
                             "../core-services/prow/02_config", repo, "_prowconfig.yaml")

    # Check if the file exists
    if not os.path.isfile(yaml_file):
        print(f"YAML file not found: {yaml_file}")
        sys.exit(1)

    with open(yaml_file, 'r', encoding='utf-8') as file:
        config = yaml.safe_load(file)

    if revert:
        new_queries = []
        for query in config['tide']['queries']:
            if 'includedBranches' in query and branch_to_split in query['includedBranches']:
                if len(query['includedBranches']) == 1:
                    continue  # Remove this query as it's the split-out branch
                query['includedBranches'].remove(branch_to_split)
            new_queries.append(query)

        # Add the branch back to the original query
        new_queries[0]['includedBranches'].append(branch_to_split)
        config['tide']['queries'] = new_queries
    else:
        queries = config['tide']['queries'][0] # Don't assume it's the only one
        new_query = copy.deepcopy(queries)

        if branch_to_split in queries['includedBranches']:
            queries['includedBranches'].remove(branch_to_split)
            new_query['includedBranches'] = [branch_to_split]
            new_query['labels'].append('acknowledge-critical-fixes-only')
            config['tide']['queries'].append(new_query)
        else:
            print(f"Branch '{branch_to_split}' not found in the includedBranches.")
            return

    with open(yaml_file, 'w', encoding='utf-8') as file:
        yaml.safe_dump(config, file, default_flow_style=False, sort_keys=False)

    print(f"Updated YAML written to {yaml_file}")

if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: python script.py <repo> <branch_to_split> <--apply|--revert>")
        sys.exit(1)

    arg_repo = sys.argv[1]
    arg_branch_to_split = sys.argv[2]
    arg_action = sys.argv[3]

    if arg_action == "--apply":
        split_out_branch(arg_repo, arg_branch_to_split)
    elif arg_action == "--revert":
        split_out_branch(arg_repo, arg_branch_to_split, revert=True)
    else:
        print("Invalid action. Use --apply to apply changes or --revert to revert changes.")
        sys.exit(1)
