#!/usr/bin/env python

import sys

from github3 import login
from kubernetes.client.rest import ApiException
from openshift import config
from openshift.client import UserOpenshiftIoV1Api, V1Group
from yaml import load


def main(argv):
    if len(argv) != 2:
        print('Incorrect number of arguments passed. Specify an API token and group mapping file.')
        exit(1)
    else:
        sync_groups(argv[0], argv[1])


def sync_groups(oauth_token_path, sync_spec_path):
    config.load_incluster_config()
    ouserclient = UserOpenshiftIoV1Api()
    for name, members in build_origin_groups(oauth_token_path, sync_spec_path).items():
        existing_group = get_or_init_group(ouserclient, name)
        existing_group.users = members
        ouserclient.replace_user_openshift_io_v1_group(name, existing_group)


def build_origin_groups(oauth_token_path, sync_spec_path):
    with open(oauth_token_path) as oauth_token_file:
        oauth_token = oauth_token_file.read()

    with open(sync_spec_path) as sync_spec_file:
        sync_spec = load(sync_spec_file)

    org = login(token=oauth_token).organization(sync_spec['organization'])

    group_mapping = {}
    for group in ['admins', 'editors', 'viewers']:
        group_mapping['jenkins-{}'.format(group)] = fetch_github_team_members(org, sync_spec[group])

    return group_mapping


def fetch_github_team_members(org, team_ids):
    members = set()
    for team_id in team_ids:
        for member in org.team(team_id).iter_members():
            members.add(member.login)

    return list(members)


def get_or_init_group(ouserclient, name):
    try:
        return ouserclient.read_user_openshift_io_v1_group(name)
    except ApiException as exception:
        if exception.status == 404:
            return V1Group(metadata={'name': name})
        else:
            raise exception


if __name__ == '__main__':
    main(sys.argv[1:])
