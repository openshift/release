import json, sys, yaml;

def duplicate_branch_check(jobs):
  count = 0
  by_name = {}
  for job in jobs:
    by_name[job['name']] = job
  for job in jobs:
    for name in by_name:
      if name == job['name']:
        continue
      if job['name'].startswith(name):
        other = by_name[name]
        if 'branches' not in job:
          print "error: job %s is set to cover all branches and overlaps with job %s" % (job['name'], other['name'])
          count += 1
          continue
        if 'branches' not in other:
          print "error: job %s is set to cover all branches and overlaps with job %s" % (other['name'], job['name'])
          count += 1
          continue
        shared = list(set(job['branches']) & set(other['branches']))
        if len(shared) > 0:
          print "error: job %s has branch overlap with job %s: %s" % (other['name'], job['name'], shared)
          count += 1
          continue
  return count

errors = 0
y = yaml.load(open(sys.argv[1]))
for name in y['postsubmits']:
  errors += duplicate_branch_check(y['postsubmits'][name])
for name in y['presubmits']:
  errors += duplicate_branch_check(y['presubmits'][name])
if errors > 0:
  exit(1)
