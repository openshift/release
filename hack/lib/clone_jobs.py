from __future__ import print_function;
import json, sys, copy;
import ruamel.yaml as yaml; # ruamel allows us to preserve formatting

def duplicate_job(job, from_branch, to_branch):
  if 'branches' not in job:
    return []
  for name in job['branches']:
    if name == from_branch:
      n = copy.deepcopy(job)
      n['branches'] = [to_branch]
      name = n['name']
      if "master" in name:
        n['name'] = name.replace("master", to_branch)
      else:
        n['name'] = name + "-" + to_branch
      return [n]
  return []

filename = sys.argv[1]
from_branch = sys.argv[2]
to_branch = sys.argv[3]
to_version = sys.argv[4]
y = yaml.load(open(filename), yaml.RoundTripLoader)
count = 0
for t in ['postsubmits','presubmits']:
  if t in y:
    for repo in y[t]:
      newjobs = []
      for job in y[t][repo]:
        newjobs += duplicate_job(job, from_branch, to_branch)
      count += len(newjobs)
      y[t][repo] = newjobs
if count > 0:
  out = yaml.dump(y, default_flow_style=False, Dumper=yaml.RoundTripDumper)
  out = out.replace(from_branch+'.yaml', to_branch+'.yaml')
  print(out)
