#!/usr/bin/env python3

import os
import re
import sys
import ruamel.yaml as yaml; # ruamel allows us to preserve formatting

JOBS_DIR = 'ci-operator/jobs'

def main():
    with open('ci-operator/testgrid/testgrid-config.yaml') as f:
      grid = yaml.safe_load(f)

    groups = {}
    for group in grid.get('test_groups', []):
      if group['name'] in groups:
        print("[ERROR] group name {} defined twice".format(group.name))
        sys.exit(1)
      groups[group['name']] = group
    
    for root, _, files in os.walk(JOBS_DIR):
        for filename in files:
            if not filename.endswith('.yaml'):
                continue
            if os.path.basename(filename) == "infra-periodics.yaml":
                continue
            path = os.path.join(root, filename)
            with open(path) as f:
                data = yaml.safe_load(f)
                merge_groups_from_jobs(grid, groups, data)

    all_groups = []
    for group_name in groups:
      all_groups.append(groups[group_name])
    all_groups.sort(key=lambda group: group['name'])
    grid['test_groups'] = all_groups

    print yaml.dump(grid, default_flow_style=False, Dumper=yaml.RoundTripDumper)

def merge_groups_from_jobs(grid, groups, jobs):
  for t in ['presubmits', 'postsubmits']:
    if t in jobs:
      for repo_name in jobs[t]:
        for job in jobs[t][repo_name]:
          group = {}
          group['name'] = job['name']
          if t == 'postsubmits':
            group['gcs_prefix'] = "origin-ci-test/logs/{}".format(job['name'])
          else:
            group['gcs_prefix'] = "origin-ci-test/pr-logs/directory/{}".format(job['name'])
          groups[job['name']] = group
  for t in ['periodics']:
    if t in jobs:
      for job in jobs[t]:
        group = {}
        group['name'] = job['name']
        group['gcs_prefix'] = "origin-ci-test/logs/{}".format(job['name'])
        groups[job['name']] = group

main()
