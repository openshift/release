import json, sys, yaml, os, fnmatch, re;

basename = '*.yaml'
dir = 'ci-operator/config'

count = 0
for dirpath, dirnames, filenames in os.walk(dir):
  parts = dirpath.split('/')[2:]
  prefix = '-'.join(parts) + '-'
  for f in fnmatch.filter(filenames, basename):
    name = f.split('.yaml')[0]
    branch = name.split('__')[0][len(prefix):]

    y = yaml.load(open(os.path.join(dirpath, f)))
    if 'promotion' not in y:
      continue
    if y['promotion'].get('namespace','') != 'ocp' or y['promotion'].get('name','') not in ['4.0', '4.1', '4.2']:
      continue

    print '/'.join([parts[0], parts[1], branch])

if count == 0:
  exit(1)