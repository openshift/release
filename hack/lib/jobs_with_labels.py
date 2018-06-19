import json, sys, yaml;

y = yaml.load(open(sys.argv[1]))
if 'postsubmits' in y and sys.argv[2] in y['postsubmits']:
  jobs = y['postsubmits'][sys.argv[2]]
else:
  jobs = []
if len(sys.argv) > 3:
  jobs = list(filter(lambda x: 'branches' in x and sys.argv[3] in x['branches'], jobs))
if len(sys.argv) > 4:
  jobs = list(filter(lambda x: 'labels' in x and sys.argv[4] in x['labels'], jobs))
if len(jobs) == 0:
  exit(1)
for job in jobs:
  print job['name']