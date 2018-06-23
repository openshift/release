import json, sys, yaml;

def check_jobs(config, job_type):
  count = 0
  by_name = {}
  for repo in config[job_type]:
    jobs = config[job_type][repo]
    for job in jobs:
      job['repo'] = repo
      if job['name'] in by_name:
        print "error: job %s is defined under multiple repos in %s: %s and %s" % (job['name'], job_type, repo, by_name[job['name']]['repo'])
        count += 1
        continue
  return count

errors = 0

y = yaml.load(open(sys.argv[1]))
for job_type in ('postsubmits', 'presubmits'):
  errors += check_jobs(y, job_type)

if errors > 0:
  exit(1)
