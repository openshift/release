#!/usr/bin/env python3

import sys
import os
import json

data = {}

with open(sys.argv[2]) as raw:
    data = json.load(raw)

# Filter functions operate on the JSON object emitted on a structured log line
# and return true if the log line should be displayed, false otherwise. Unless
# all filters agree that a line should be displayed, it will be filtered out.
mode = sys.argv[1]
filters = []
if mode == "warnings":
    filters = [
        # deck spews a lot of useless warnings
        lambda message: message.get("component", "") == "deck" and
        any(
            any(s in message.get(m, "") for m in ["msg", "error"]) for s in [
                "object doesn't exist",
                "failed to read started.json",
                "Error getting ProwJob name for source"
            ]
        ),
        lambda message: any(
            s in message.get("msg", "") for s in [
                "Throttled clientside for more than 15 minutes",  # this is just token contention
                "empty -github-token-path, will use anonymous github client",  # this is expected and OK
                "Unable to add nonexistent labels",  # if the users cared they'd do something
                "unrecognized file name (expected <int64>.txt)"  # https://github.com/kubernetes/test-infra/issues/22256
            ]
        ),
        lambda message: any(
            any(s in message.get(m, "") for m in ["msg", "error"]) for s in [
                "You have triggered an abuse detection mechanism.",  # nothing to do post-hoc for this
                "Something went wrong while executing your query. This may be the result of a timeout, or it could be a GitHub bug."  # nothing to do post-hoc
            ]
        ),
        # nothing we can do
        lambda message: message.get("component", "") == "needs-rebase" and "Query returned 1k PRs" in message.get("msg", ""),
        # this is expected and ok
        lambda message: message.get("component", "") == "cherrypicker" and "failed to apply PR on top" in message.get("msg", ""),
        # ghproxy outage
        lambda message: any(
            "http://ghproxy/graphql" in message.get(m, "") and
            any(
                s in message.get(m, "") for s in ["connect: connection refused", "i/o timeout"]
            ) for m in ["msg", "error"]
        )
    ]
elif mode == "errors":
    filters = [
        lambda message: any(
            s in message.get("msg", "") for s in [
                "Throttled clientside for more than 15 minutes",  # this is just token contention
                "Query returned 1k PRs",  # nothing to do
                "unrecognized file name (expected <int64>.txt)",  # https://github.com/kubernetes/test-infra/issues/22256
                "Getting plugin help from hook."  # https://github.com/kubernetes/test-infra/issues/21426
            ]
        ),
        lambda message: any(
            s in message.get("error", "") for s in [
                "sleep time for token reset exceeds max sleep time",  # this is emitted when we run out of tokens, nothing to do post-hoc for this
                "not accessible",  # https://github.com/kubernetes/test-infra/issues/22251
                "leader election lost"  # why is this even an error?
            ]
        ),
        lambda message: any(
            any(s in message.get(m, "") for m in ["msg", "error"]) for s in [
                "You have triggered an abuse detection mechanism.",  # nothing to do post-hoc for this
                "Something went wrong while executing your query. This may be the result of a timeout, or it could be a GitHub bug."  # nothing to do post-hoc
            ]
        ),
        # this happens on redeploy and nothing we can do post-hoc
        lambda message: "Error dispatching event to external plugin." in message.get("msg", "") or any(
            s in message.get("error", "") for s in ["i/o timeout", "connection refused"]
        ),
        # why???
        lambda message: any(
            s in message.get("error", "") for s in ["context canceled", "context deadline exceeded"]
        ) and any(
            s in message.get("component", "") for s in ["crier", "dptp-controller-manager", 'prow-controller-manager']
        ) or message.get("logger", "") == "controller-runtime",
        # do we even care?
        lambda message: "kata-jenkins-operator" in json.dumps(message),
        lambda message: "ci-operator-configresolver" in message.get("component", "") and any(
            s in message.get("error", "") for s in [
                "connection reset by peer", "broken pipe",  # redeploy?
                "no workflow named"  # user error? should not be an error?
            ]
        ),
        # deck trying to talk to Tide, this fails when we bump. We have probes in Tide so we get alerted when it's down for longer time.
        lambda message: "deck" in message.get("component", "") and
        "Updating" in message.get("msg", "") and
        any(s in message.get("error", "") for s in ["connect: connection refused", "i/o timeout"]),
        # ghproxy outage
        lambda message: any(
            "http://ghproxy/graphql" in message.get(m, "") and
            any(
                s in message.get(m, "") for s in ["connect: connection refused", "i/o timeout"]
            ) for m in ["msg", "error"]
        )
    ]
else:
    print("Filter mode must be 'warnings' or 'errors', not " + mode)


def aggregate_filter(entry):
    keep = True
    for field in entry:
        if field["field"] == "@message":
            raw_entry = json.loads(field["value"])
            for f in filters:
                keep = keep and not f(raw_entry)
    return keep

print(json.dumps(list(filter(aggregate_filter, data["results"]))))
