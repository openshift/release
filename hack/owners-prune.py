#!/usr/bin/env python

import logging
import os
import subprocess
import re
import textwrap
import urllib.parse

import github


logging.basicConfig(format='%(levelname)s: %(message)s')
_LOGGER = logging.getLogger(__name__)
_LOGGER.setLevel(logging.DEBUG)


def prune_owners(repository, owners, github_token, upstream_remote='origin', upstream_branch='master', personal_remote=None, message=None, prune_files=None):
    if prune_files is None:
        prune_files = {'OWNERS', 'OWNERS_ALIASES'}

    prune_regexp = re.compile('|'.join(sorted(owners)))

    process = subprocess.run(['git', '-C', repository, 'remote', 'get-url', '--push', upstream_remote], check=True, capture_output=True, text=True)
    upstream_uri = urllib.parse.urlsplit(process.stdout.strip())
    if not upstream_uri.path.startswith('/'):
        raise ValueError('expected a GitHub URI with an opening slash, not {!r}'.format(upstream_uri.path))
    github_repo, _ = os.path.splitext(upstream_uri.path[1:])

    if personal_remote:
        process = subprocess.run(['git', '-C', repository, 'remote', 'get-url', '--push', personal_remote], check=True, capture_output=True, text=True)
        upstream_uri = urllib.parse.urlsplit(process.stdout.strip())

    _, have_user_info, host_info = upstream_uri.netloc.rpartition('@')
    if have_user_info and upstream_uri.scheme == 'https':
        push_uri = urllib.parse.urlunsplit(upstream_uri)
    else:
        push_uri = urllib.parse.urlunsplit(upstream_uri._replace(
            scheme='https',
            netloc='{}@{}'.format(github_token, host_info),
        ))

    subprocess.run(['git', '-C', repository, 'fetch', upstream_remote], check=True)
    branch = 'prune-owners'
    try:
        subprocess.run(['git', '-C', repository, 'show', branch], check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as error:
        if 'unknown revision or path not in the working tree' not in error.stderr:
            raise
    else:
        raise ValueError('branch {} already exists; possibly waiting for an open pull request to merge'.format(branch))
    subprocess.run(['git', '-C', repository, 'checkout', '-b', branch, '{}/{}'.format(upstream_remote, upstream_branch)], check=True)

    touched = set()
    for dirname, _, filenames in os.walk(repository):
        for filename in filenames:
            if filename not in prune_files:
                continue
            path = os.path.join(dirname, filename)
            with open(path) as f:
                data = f.read()
            output = ''.join(line for line in data.splitlines(keepends=True) if not prune_regexp.search(line))
            if output != data:
                touched.add(os.path.relpath(path, repository))
                _LOGGER.info('remove owners from {}'.format(path))
                with open(path, 'w') as f:
                    f.write(output)

    if not touched:
        raise ValueError('none of {} found in any {} files'.format('|'.join(sorted(owners)), '|'.join(sorted(prune_files))))

    subject = 'OWNERS: Prune {}'.format(', '.join(sorted(owners)))
    body = '{}\n\n{}\n'.format(subject, textwrap.fill(message, width=76))
    subprocess.run(['git', '-C', repository, 'commit', '--file', '-'] + sorted(touched), check=True, encoding='utf-8', input=body)
    subprocess.run(['git', '-C', repository, 'push', '-u', push_uri, branch], check=True)

    github_object = github.Github(github_token)
    repo = github_object.get_repo(github_repo)
    head = branch
    if personal_remote:
        head = '{}:{}'.format(personal_remote, head)
    _LOGGER.debug('create pull request in {} from {} for {}'.format(github_repo, head, upstream_branch))
    pull = repo.create_pull(title=subject, body=message, head=head, base=upstream_branch)
    _LOGGER.info('created {}'.format(pull.html_url))
    return pull


if __name__ == '__main__':
    import argparse

    parser = argparse.ArgumentParser(
        description='Prune owners from repositories.',
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        '-r'
        '--repository',
        dest='repositories',
        metavar='PATH',
        nargs='+',
        help='Path to local repository checkout.',
    )
    parser.add_argument(
        dest='owners',
        metavar='OWNER',
        nargs='+',
        help='An owner to prune.',
    )
    parser.add_argument(
        '-m',
        '--message',
        metavar='MESSAGE',
        help='Commit message body motivating the removal.',
    )
    parser.add_argument(
        '-p',
        '--personal-remote',
        dest='personal_remote',
        metavar='NAME',
        help='Name of your personal remote, for pushing branches when you cannot push directly to the upstream repository.',
    )
    parser.add_argument(
        '--github-token',
        dest='github_token',
        metavar='TOKEN',
        help='GitHub token for pull request creation ( https://docs.github.com/en/github/authenticating-to-github/keeping-your-account-and-data-secure/creating-a-personal-access-token ). Defaults to the value of the GITHUB_TOKEN environment variable.',
        default=os.environ.get('GITHUB_TOKEN', ''),
    )

    args = parser.parse_args()

    for repository in args.repositories:
        prune_owners(
            repository=repository,
            owners=args.owners,
            message=args.message,
            github_token=args.github_token.strip(),
            personal_remote=args.personal_remote,
        )
