#!/usr/bin/env python

import yaml


with open('core-services/prow/02_config/_config.yaml', 'r') as f:
    data = yaml.safe_load(f)

repos = {}
for query in data['tide']['queries']:
    for repo in query.get('repos', []) + query.get('orgs', []):
        if repo not in repos:
            repos[repo] = []
        repos[repo].append(query)
    #print(query['description'])

groups = {}
for repo, queries in repos.items():
    key = tuple(sorted(query['description'] for query in queries))
    if key not in groups:
        groups[key] = set()
    groups[key].add(repo)

for key, repos in sorted(groups.items(), key=lambda key_repos: len(key_repos[1])):
    print('{} {}'.format(len(repos), ' | '.join(key)))
    #for repo in repos:
    #    print('  {}'.format(repo))
