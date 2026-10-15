# Agent TNF gather regression checks

Run `bash hack/validate-agent-tnf-gather.sh` from the release checkout. The Bash
driver executes the actual registry command scripts and their rendered remote
heredocs with synthetic provisioning/SSH/SCP commands. The retained agent helper
is represented by its rendezvous-address interface, not by a consumed manifest;
fencing hostname and MAC identifiers share the same IP/hostname hosts fixture.
No extra runtime helper is injected into the CI step.

Run the same driver in `registry.ci.openshift.org/ocp-kni/test:dev-scripts` for
consumer-image evidence. Mocked transport checks are not a failed installation
or evidence that uploaded packed archives survive censorship or are readable.
Positive synthetic Pacemaker, podman-etcd and journal archives exercise the
existing collectors and node SCP for both fencing identifiers, including
Pacemaker credential redaction and continuation after an unreachable first node.
The fixtures model common.sh xtrace/nocasematch and the rendezvous helper's
subshell-local strict options; they do not source private configurations.
The unchanged upstream agent gather can delete unsuccessful node streams before
release sees them; retrieving existing bundles cannot restore deleted streams.
