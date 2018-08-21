import json, sys, yaml;

y = yaml.load(open(sys.argv[1]))
if 'postsubmits' not in y:
  exit(1)
for repo in y['postsubmits']:
  if len(sys.argv[2]) > 0 and sys.argv[2] != repo:
    continue
  jobs = y['postsubmits'][repo]
  if len(sys.argv) > 3:
    jobs = list(filter(lambda x: 'branches' in x and sys.argv[3] in x['branches'], jobs))
  if len(sys.argv) > 4:
    jobs = list(filter(lambda x: 'labels' in x and sys.argv[4] in x['labels'], jobs))
  if len(jobs) > 0:
    print repo
