#!/usr/bin/env python2

# Copyright 2017 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

'''
Summarize groups failed tests together by finding edit distances between their failure strings,
and emits JSON for rendering in a browser.
'''

# pylint: disable=invalid-name,missing-docstring


import argparse
import functools
import hashlib
import json
import os
import re
import sys
import time
import zlib

import berghelroach

editdist = berghelroach.dist

flakeReasonDateRE = re.compile(
    r'[A-Z][a-z]{2}, \d+ \w+ 2\d{3} [\d.-: ]*([-+]\d+)?|'
    r'\w{3}\s+\d{1,2} \d+:\d+:\d+(\.\d+)?|(\d{4}-\d\d-\d\d.|.\d{4} )\d\d:\d\d:\d\d(.\d+)?')
# Find random noisy strings that should be replaced with renumbered strings, for more similarity.
flakeReasonOrdinalRE = re.compile(
    r'0x[0-9a-fA-F]+' # hex constants
    r'|\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(:\d+)?' # IPs + optional port
    r'|[0-9a-fA-F]{8}-\S{4}-\S{4}-\S{4}-\S{12}(-\d+)?' # UUIDs + trailing digits
    r'|[0-9a-f]{12,32}' # hex garbage
    r'|(?<=minion-group-|default-pool-)[-0-9a-z]{4,}'  # node names
)


def normalize(s):
    """
    Given a traceback or error message from a text, reduce excess entropy to make
    clustering easier.

    This includes:
    - blanking dates and timestamps
    - renumbering unique information like
        - pointer addresses
        - UUIDs
        - IP addresses
    - sorting randomly ordered map[] strings.
    """

    # blank out dates
    s = flakeReasonDateRE.sub('TIME', s)

    # do alpha conversion-- rename random garbage strings (hex pointer values, node names, etc)
    # into 'UNIQ1', 'UNIQ2', etc.
    matches = {}
    def repl(m):
        s = m.group(0)
        if s not in matches:
            matches[s] = 'UNIQ%d' % (len(matches) + 1)
        return matches[s]

    if 'map[' in s:
        # Go's maps are in a random order. Try to sort them to reduce diffs.
        s = re.sub(r'map\[([^][]*)\]',
                   lambda m: 'map[%s]' % ' '.join(sorted(m.group(1).split())),
                   s)

    s = flakeReasonOrdinalRE.sub(repl, s)

    if len(s) > 10000:
        # for long strings, remove repeated lines!
        s = re.sub(r'(?m)^(.*\n)\1+', r'\1', s)

    if len(s) > 200000:  # ridiculously long test output
        s = s[:100000] + '\n...[truncated]...\n' + s[-100000:]

    return s

def normalize_name(name):
    """
    Given a test name, remove [...]/{...}.

    Matches code in testgrid and kubernetes/hack/update_owners.py.
    """
    name = re.sub(r'\[.*?\]|\{.*?\}', '', name)
    name = re.sub(r'\s+', ' ', name)
    return name.strip()


def make_ngram_counts(s, ngram_counts={}):
    """
    Convert a string into a histogram of frequencies for different byte combinations.
    This can be used as a heuristic to estimate edit distance between two strings in
    constant time.

    Instead of counting each ngram individually, they are hashed into buckets.
    This makes the output count size constant.
    """

    # Yes, I'm intentionally memoizing here.
    # pylint: disable=dangerous-default-value

    size = 64
    if s not in ngram_counts:
        counts = [0] * size
        for x in xrange(len(s)-3):
            counts[zlib.crc32(s[x:x+4].encode('utf8')) & (size - 1)] += 1
        ngram_counts[s] = counts  # memoize
    return ngram_counts[s]


def ngram_editdist(a, b):
    """
    Compute a heuristic lower-bound edit distance using ngram counts.

    An insert/deletion/substitution can cause up to 4 ngrams to differ:

    abcdefg => abcefg
    (abcd, bcde, cdef, defg) => (abce, bcef, cefg)

    This will underestimate the edit distance in many cases:
    - ngrams hashing into the same bucket will get confused
    - a large-scale transposition will barely disturb ngram frequencies,
      but will have a very large effect on edit distance.

    It is useful to avoid more expensive precise computations when they are
    guaranteed to exceed some limit (being a lower bound), or as a proxy when
    the exact edit distance computation is too expensive (for long inputs).
    """
    counts_a = make_ngram_counts(a)
    counts_b = make_ngram_counts(b)
    return sum(abs(x-y) for x, y in zip(counts_a, counts_b))/4


def make_ngram_counts_digest(s):
    """
    Returns a hashed version of the ngram counts.
    """
    return hashlib.sha1(str(make_ngram_counts(s))).hexdigest()[:20]


def file_memoize(description, name):
    """
    Decorator to save a function's results to a file.
    """
    def inner(func):
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            if os.path.exists(name):
                data = json.load(open(name))
                print 'done (cached)', description
                return data
            data = func(*args, **kwargs)
            json.dump(data, open(name, 'w'))
            print 'done', description
            return data
        wrapper.__wrapped__ = func
        return wrapper
    return inner


@file_memoize('loading failed tests', 'failed.json')
def load_failures(builds_file, tests_files):
    builds = {}
    for build in json.load(open(builds_file)):
        if not build['started'] or not build['number']:
            continue
        for attr in ('started', 'tests_failed', 'number', 'tests_run'):
            build[attr] = int(build[attr])
        build['elapsed'] = int(float(build['elapsed']))
        if 'pr-logs' in build['path']:
            build['pr'] = build['path'].split('/')[-3]
        builds[build['path']] = build

    failed_tests = {}
    for tests_file in tests_files:
        for test in json.load(open(tests_file)):
            failed_tests.setdefault(test['name'], []).append(test)
    for tests in failed_tests.itervalues():
        tests.sort(key=lambda t: t['build'])

    return builds, failed_tests


def find_match(fnorm, clusters):
    for ngram_dist, other in sorted((ngram_editdist(fnorm, x), x) for x in clusters):
        # allow up to 10% differences
        limit = int((len(fnorm)+len(other))/2.0 * 0.10)

        if ngram_dist > limit:
            continue

        if limit <= 1 and other != fnorm:  # no chance
            continue

        dist = editdist(fnorm, other, limit)

        if dist < limit:
            return other


def cluster_test(tests):
    """
    Compute failure clusters given a list of failures for one test.

    Args:
        tests: list of failed test dictionaries, with 'failure_text' keys
    Returns:
        {failure_text: [failure_in_cluster_1, failure_in_cluster_2, ...]}
    """
    clusters = {}
    start = time.time()

    for test in tests:
        ftext = test['failure_text']
        fnorm = normalize(ftext)
        if fnorm in clusters:
            clusters[fnorm].append(test)
        else:
            other = find_match(fnorm, clusters)
            if other:
                clusters[other].append(test)
            else:
                clusters[fnorm] = [test]
        if time.time() > start + 60:
            print 'bailing early, taking too long!'
            break
    return clusters


@file_memoize('clustering inside each test', 'failed_clusters_local.json')
def cluster_local(failed_tests):
    """Cluster together the failures for each test. """
    clustered = {}
    for test_name, tests in sorted(failed_tests.iteritems(), key=lambda x: len(x[1]), reverse=True):
        print len(tests), test_name,
        sys.stdout.flush()
        clustered[test_name] = cluster_test(tests)
        print len(clustered[test_name])
    return clustered


@file_memoize('clustering across tests', 'failed_clusters_global.json')
def cluster_global(clustered, previous_clustered):
    """Combine together clustered failures for each test.

    This is done hierarchically for efficiency-- each test's failures are likely to be similar,
    reducing the number of clusters that need to be paired up at this stage.

    Args:
        {test_name: {failure_text: [failure_1, failure_2, ...], ...}, ...}
    Returns:
        {failure_text: [(test_name, [failure_1, failure_2, ...]), ...], ...}
    """
    clusters = {}

    if previous_clustered:
        # seed clusters using output from the previous run
        n = 0
        for cluster in previous_clustered:
            key = cluster['key']
            if key != normalize(key):
                print key
                print normalize(key)
                n += 1
                continue
            clusters[cluster['key']] = {}
        print 'Seeding with %d previous clusters' % len(clusters)
        if n:
            print '!!! %d clusters lost from different normalization! !!!' % n


    for n, (test_name, cluster) in enumerate(
            sorted(clustered.iteritems(),
                   key=lambda (k, v): sum(len(x) for x in v.itervalues()),
                   reverse=True),
            1):
        print '%d/%d %d %s' % (n, len(clustered), len(cluster), test_name)
        for key, tests in sorted(cluster.iteritems(), key=lambda x: len(x[1]), reverse=True):
            if key in clusters:
                clusters[key].setdefault(test_name, []).extend(tests)
            else:
                other = find_match(key, clusters)
                if other:
                    clusters[other].setdefault(test_name, []).extend(tests)
                else:
                    clusters[key] = {test_name: list(tests)}

    # If we seeded clusters using the previous run's keys, some of those
    # clusters may have disappeared. Remove the resulting empty entries.
    for k in {k for k, v in clusters.iteritems() if not v}:
        clusters.pop(k)

    return clusters


def tests_group_by_job(tests, builds):
    """Turn a list of test failures into {job: [buildnumber, ...], ...}"""
    groups = {}
    for test in tests:
        try:
            build = builds[test['build']]
        except KeyError:
            continue
        if 'number' in build:
            groups.setdefault(build['job'], set()).add(build['number'])
    return sorted(((key, sorted(value, reverse=True)) for key, value in groups.iteritems()),
                  key=lambda (k, v): (-len(v), k))


SPAN_RE = re.compile(r'\w+|\W+')

def common_spans(xs):
    """
    Finds something similar to the longest common subsequence of xs, but much faster.

    Returns a list of [matchlen_1, mismatchlen_2, matchlen_2, mismatchlen_2, ...], representing
    sequences of the first element of the list that are present in all members.
    """
    common = None
    for x in xs:
        x_split = SPAN_RE.findall(x)
        if common is None:  # first iteration
            common = set(x_split)
        else:
            common.intersection_update(x_split)

    spans = []
    match = True
    span_len = 0
    for x in SPAN_RE.findall(xs[0]):
        if x in common:
            if not match:
                match = True
                spans.append(span_len)
                span_len = 0
            span_len += len(x)
        else:
            if match:
                match = False
                spans.append(span_len)
                span_len = 0
            span_len += len(x)

    if span_len:
        spans.append(span_len)

    return spans


def clusters_to_display(clustered, builds):
    """Transpose and sort the output of cluster_global."""

    return [{
        "key": key,
        "id": key_id,
        "spans": common_spans([f['failure_text'] for _, fs in clusters for f in fs]),
        "text": clusters[0][1][0]['failure_text'],
        "tests": [{
            "name": test_name,
            "jobs": [{"name": n, "builds": b}
                     for n, b in tests_group_by_job(tests, builds)]
            }
                  for test_name, tests in sorted(clusters, key=lambda (n, t): (-len(t), n))
                 ]
        }
            for key, key_id, clusters in clustered if sum(len(x[1]) for x in clusters) > 1
           ]


def builds_to_columns(builds):
    """Convert a list of build dictionaries into a columnar form.

    This compresses much better with gzip."""

    jobs = {}

    cols = {v: [] for v in 'started tests_failed elapsed tests_run result executor pr'.split()}
    out = {'jobs': jobs, 'cols': cols, 'job_paths': {}}
    for build in sorted(builds.itervalues(), key=lambda b: (b['job'], b['number'])):
        if 'number' not in build:
            continue
        index = len(cols['started'])
        for key, entries in cols.iteritems():
            entries.append(build.get(key))
        job = jobs.setdefault(build['job'], {})
        if not job:
            out['job_paths'][build['job']] = build['path'][:build['path'].rindex('/')]
        job[build['number']] = index

    for k, indexes in jobs.items():
        numbers = sorted(indexes)
        base = indexes[numbers[0]]
        count = len(numbers)

        # optimization: if we have a dense sequential mapping of builds=>indexes,
        # store only the first build number, the run length, and the first index number.
        if numbers[-1] == numbers[0] + count - 1 and \
                all(indexes[k] == n + base for n, k in enumerate(numbers)):
            jobs[k] = [numbers[0], count, base]
            for n in numbers:
                assert n <= numbers[0] + len(numbers), (k, n, jobs[k], len(numbers), numbers)

    return out


def render(builds, clustered):
    clustered_sorted = sorted(
        clustered.iteritems(),
        key=lambda (k, v): (-sum(len(ts) for ts in v.itervalues()), k))
    clustered_tuples = [(k,
                         make_ngram_counts_digest(k),
                         sorted(clusters.items(), key=lambda (n, t): (-len(t), n)))
                        for k, clusters in clustered_sorted]

    return {'clustered': clusters_to_display(clustered_tuples, builds),
            'builds': builds_to_columns(builds)}


SIG_LABEL_RE = re.compile(r'\[sig-([^]]*)\]')

def annotate_owners(data, builds, owners):
    """
    Assign ownership to a cluster based on the share of hits in the last day.
    """
    owner_re = re.compile(r'(?:%s)' % '|'.join(
        '(?P<%s>%s)' % (
            sig.replace('-', '_'),  # regex group names can't have -
            '|'.join(re.escape(p) for p in prefixes)
        )
        for sig, prefixes in owners.iteritems()
    ))
    job_paths = data['builds']['job_paths']
    yesterday = max(data['builds']['cols']['started']) - (60 * 60 * 24)

    for cluster in data['clustered']:
        owner_counts = {}
        for test in cluster['tests']:
            m = SIG_LABEL_RE.search(test['name'])
            if m:
                owner = m.group(1)
            else:
                m = owner_re.match(normalize_name(test['name']))
                if not m or not m.groupdict():
                    continue
                owner = next(k for k, v in m.groupdict().iteritems() if v)
            owner = owner.replace('_', '-')
            counts = owner_counts.setdefault(owner, [0, 0])
            for job in test['jobs']:
                if ':' in job['name']:  # non-standard CI
                    continue
                job_path = job_paths[job['name']]
                for build in job['builds']:
                    if builds['%s/%d' % (job_path, build)]['started'] > yesterday:
                        counts[0] += 1
                    else:
                        counts[1] += 1
        if owner_counts:
            owner = max(owner_counts.items(), key=lambda (o, c): (c, o))[0]
            cluster['owner'] = owner
        else:
            cluster['owner'] = 'testing'


def render_slice(data, builds, prefix='', owner=''):
    clustered = []
    builds_out = {}
    jobs = set()
    for cluster in data['clustered']:
        # print [cluster['id'], prefix]
        if owner and cluster.get('owner') == owner:
            clustered.append(cluster)
        elif prefix and cluster['id'].startswith(prefix):
            clustered.append(cluster)
        else:
            continue
        for test in cluster['tests']:
            for job in test['jobs']:
                jobs.add(job['name'])
    for path, build in builds.iteritems():
        if build['job'] in jobs:
            builds_out[path] = build
    return {'clustered': clustered, 'builds': builds_to_columns(builds_out)}


def parse_args(args):
    parser = argparse.ArgumentParser()
    parser.add_argument('builds', help='builds.json file from BigQuery')
    parser.add_argument('tests', help='tests.json file from BigQuery', nargs='+')
    parser.add_argument('--previous', help='previous output', type=argparse.FileType('r'))
    parser.add_argument('--owners', help='test owner SIGs', type=argparse.FileType('r'))
    parser.add_argument('--output', default='failure_data.json')
    parser.add_argument('--output_slices',
                        help='Output slices to this path (must include PREFIX in template)')
    return parser.parse_args(args)


def main(args):
    builds, failed_tests = load_failures(args.builds, args.tests)

    previous_clustered = None
    if args.previous:
        print 'loading previous'
        previous_clustered = json.load(args.previous)['clustered']

    clustered_local = cluster_local(failed_tests)
    clustered = cluster_global(clustered_local, previous_clustered)

    print '%d clusters' % len(clustered)

    data = render(builds, clustered)

    if args.owners:
        owners = json.load(args.owners)
        annotate_owners(data, builds, owners)

    json.dump(data, open(args.output, 'w'),
              sort_keys=True)

    if args.output_slices:
        assert 'PREFIX' in args.output_slices
        for subset in range(256):
            id_prefix = '%02x' % subset
            json.dump(render_slice(data, builds, id_prefix),
                      open(args.output_slices.replace('PREFIX', id_prefix), 'w'),
                      sort_keys=True)
        if args.owners:
            owners.setdefault('testing', [])  # for output
            for owner in owners:
                json.dump(render_slice(data, builds, prefix='', owner=owner),
                          open(args.output_slices.replace('PREFIX', 'sig-' + owner), 'w'),
                          sort_keys=True)


if __name__ == '__main__':
    main(parse_args(sys.argv[1:]))
