#!/usr/bin/env python3

import json
import sys

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
                "Error getting ProwJob name for source",
                "failed to get job history: invalid url /job-history/",
                "error rendering spyglass page: error when resolving real path",
                "Cookie secret should be exactly 32 bytes. Consider truncating the existing cookie to that length" # https://issues.redhat.com/browse/DPTP-2615
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
        ),
        lambda message: matches(message, "tide", error="non-200 OK status code: 403 Forbidden"),
        lambda message: matches(message, "tide", msg="GitHub status description needed to be truncated to fit GH API limit"),
        # our automation doesn't have access to the repo
        lambda message: matches(message, "hook", msg="Could not list labels on PR", error="the GitHub API request returns a 403"),
        lambda message: any(
            s in message.get("error", "") for s in ["context canceled", "context deadline exceeded", "net/http: request canceled"]
        ) and any(
            s in message.get("component", "") for s in ["crier", "dptp-controller-manager", 'prow-controller-manager', "deck", "tide", "pod-scaler reloader"]
        ),
    ]
elif mode == "errors":
    filters = [
        lambda message: any(
            s in message.get("msg", "") for s in [
                "Throttled clientside for more than 15 minutes",  # this is just token contention
                "Query returned 1k PRs",  # nothing to do
                "unrecognized file name (expected <int64>.txt)",  # https://github.com/kubernetes/test-infra/issues/22256
                "unrecognized file name (expected int64)",  # https://github.com/kubernetes/test-infra/issues/22256
                "Getting plugin help from hook."  # https://github.com/kubernetes/test-infra/issues/21426
            ]
        ),
        lambda message: any(
            s in message.get("error", "") for s in [
                "sleep time for token reset exceeds max sleep time",  # this is emitted when we run out of tokens, nothing to do post-hoc for this
                "leader election lost",  # why is this even an error?
                "not accessible",  # https://github.com/kubernetes/test-infra/issues/22251
                "no client for cluster  available",  # https://issues.redhat.com/browse/DPTP-2380
                "found duplicate series for the match group",  # https://issues.redhat.com/browse/DPTP-2381
            ]
        ),
        lambda message: any(
            any(s in message.get(m, "") for m in ["msg", "error"]) for s in [
                "You have triggered an abuse detection mechanism.",  # nothing to do post-hoc for this
                "You have exceeded a secondary rate limit. Please wait a few minutes before you try again", # nothing to do post-hoc for this
                "Something went wrong while executing your query. This may be the result of a timeout, or it could be a GitHub bug.",  # nothing to do post-hoc
                "no new finalizers can be added if the object is being deleted",  # https://github.com/kubernetes/test-infra/issues/22846
            ]
        ),
        # this happens on redeploy and nothing we can do post-hoc
        lambda message: "Error dispatching event to external plugin." in message.get("msg", "") or any(
            s in message.get("error", "") for s in ["i/o timeout", "connection refused"]
        ),
        # why???
        lambda message: any(
            s in message.get("error", "") for s in ["context canceled", "context deadline exceeded", "net/http: request canceled"]
        ) and any(
            s in message.get("component", "") for s in ["crier", "dptp-controller-manager", 'prow-controller-manager', "deck", "tide"]
        ) or message.get("logger", "") == "controller-runtime",
        # do we even care?
        lambda message: "kata-jenkins-operator" in json.dumps(message),
        lambda message: "ci-operator-configresolver" in message.get("component", "") and any(
            s in message.get("error", "") for s in [
                "connection reset by peer", "broken pipe",  # redeploy?
                "no workflow named"  # user error? should not be an error?
            ]
        ),
        # deck is spamming us for no good reason
        lambda message: "deck" in message.get("component", "") and
        "error executing template" in message.get("msg", ""),
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
        ),
        # DPTP-2462
        lambda message: "vault-secret-collection-manager" in message.get("component", "") and
        "Failed to reconcile policies" in message.get("msg", "") and
        "missing client token" in message.get("error", "") and
        any(
            err in message.get("error", "") for err in ("failed to get policy", "failed to list policies")
        ),

        # Looks temporary
        lambda message: matches(message, "pod-scaler", error="server_error: server error: 504"),
        # Expected
        lambda message: matches(message, "pod-scaler", msg="Kubeconfig changed, exiting to get restarted by Kubelet and pick up the changes"),

        # This is due to rate limiting: DPTP-2449
        lambda message: "hook" in message.get("component", "") and
        (
            "Failed to list collaborators while loading RepoOwners" in message.get("msg", "") or
            "return code not 2XX: 403 Forbidden" in message.get("error", ""),
        ),

        # DPTP-2613
        lambda message: matches(message, "dptp-controller-manager", error="failed to create namespace openshift-psap"),

        # Dummy PRPQR errors, we will see it until DPTP-2577
        lambda message: matches(message, "prow-controller-manager", msg='error executing URL template: template: JobURL:1:287: executing "JobURL" at <.Spec.Refs.Repo>: nil pointer evaluating *v1.Refs.Repo'),

        lambda message: matches(message, "pj-rehearse", msg="couldn't prepare candidate"),
        lambda message: matches(message, "pj-rehearse", error="failed waiting for prowjobs to finish: timed out waiting for the condition"),
        ]

else:
    print("Filter mode must be 'warnings' or 'errors', not " + mode)

def matches(message, component, *args, **kwargs):
    if not component in message.get("component", ""):
        return False
    for field, symptom in kwargs.items():
        if not symptom in message.get(field, ""):
            return False
    return True



def aggregate_filter(entry):
    keep = True
    for field in entry:
        if field["field"] == "@message":
            raw_entry = json.loads(field["value"])
            for f in filters:
                keep = keep and not f(raw_entry)
    return keep


print(json.dumps(list(filter(aggregate_filter, data["results"]))))
