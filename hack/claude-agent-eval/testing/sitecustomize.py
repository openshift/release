"""Test only: serve the runner a fake GitHub API from a fixture file.

Python imports sitecustomize at startup from PYTHONPATH. Putting this
directory on PYTHONPATH changes nothing unless EVAL_TEST_GITHUB_FIXTURE names
a fixture (see fake_github.py); then urllib's OpenerDirector.open, which both
urlopen and the runner's redirect-guarded opener use, answers GitHub pull
request requests from it. Other requests, such as the harness releases API,
go to the real network unless the fixture scripts them. Requests are
appended as JSON lines, without credentials, to EVAL_TEST_GITHUB_LOG when
set. The runner and its bundle contain no test hook.
"""

import importlib.util
import json
import os
from pathlib import Path
import urllib.request


def install():
    fixture = os.environ.get("EVAL_TEST_GITHUB_FIXTURE")
    if not fixture:
        return
    spec = importlib.util.spec_from_file_location("fake_github", Path(__file__).with_name("fake_github.py"))
    fake_github = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fake_github)
    with open(fixture, encoding="utf-8") as stream:
        document = json.load(stream)
    fake = fake_github.FakeGitHub(document, log=os.environ.get("EVAL_TEST_GITHUB_LOG"))
    real_open = urllib.request.OpenerDirector.open

    def fake_open(director, fullurl, *args, **kwargs):
        request = fullurl if isinstance(fullurl, urllib.request.Request) else urllib.request.Request(fullurl)
        if fake.serves(request):
            timeout = kwargs.get("timeout", args[1] if len(args) > 1 else None)
            return fake(request, timeout=timeout)
        return real_open(director, fullurl, *args, **kwargs)

    urllib.request.OpenerDirector.open = fake_open


install()
