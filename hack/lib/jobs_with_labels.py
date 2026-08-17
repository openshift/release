from __future__ import print_function;
import json, sys, yaml, os, fnmatch, re;

basename = os.path.basename(sys.argv[1])
dir = os.path.dirname(sys.argv[1])

count = 0
for dirpath, dirnames, filenames in os.walk(dir):
  for f in fnmatch.filter(filenames, basename):
    y = yaml.load(open(os.path.join(dirpath, f)))
    if 'postsubmits' not in y:
      continue
    for repo in y['postsubmits']:
      if len(sys.argv[2]) > 0 and sys.argv[2] != repo:
        continue
      jobs = y['postsubmits'][repo]
      if len(sys.argv) > 3:
        jobs = list(filter(lambda x: 'branches' in x and (sys.argv[3] in x['branches'] or ("^%s$" % sys.argv[3].replace(".", "\\.")) in x['branches']), jobs))
      if len(sys.argv) > 4:
        jobs = list(filter(lambda x: 'labels' in x and sys.argv[4] in x['labels'], jobs))
      for job in jobs:
        print(job['name'])
        count += 1

if count == 0:
  exit(1)
