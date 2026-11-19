# OCPSTRAT-2100 HTTP workload

This fixture uses one HTTP image and one Deployment template for both
OCPSTRAT-2100 workload cases. Render it with three replicas for manual
provisioning (TC-014) or four replicas plus a PodDisruptionBudget and two
continuous probes for NodePool scaling (TC-012).

The fixture tests guest workload placement and Service responses. It does not
provision Nutanix VMs, approve Agents, or scale a NodePool. TC-014 must use a
separate customer-like environment; none of the CI Nutanix infrastructure
scripts are needed to deploy this workload.

## Build and image reference

Run `go test ./...`, `go vet ./...`, and `podman build -t <image-tag> .` from
this directory. Publish the image through your registry's normal process,
then use its immutable `registry/repository@sha256:<64-hex-digest>` reference.
The renderer requires a digest so both cases can record exactly which image
they ran. The image must be pullable by the guest cluster. The build context
excludes the unrelated `minimal.iso` file. The scripts require `oc`, `jq`,
Python 3, and access to the guest cluster.

## Render and deploy

Set `KUBECONFIG` to the **guest** cluster kubeconfig. Choose a short, unique
lowercase run ID. For example:

```bash
export KUBECONFIG=/path/to/guest-kubeconfig
export RUN_ID=verify01
export IMAGE_REF='quay.io/mgencur/apps@sha256:4d47a5051e93507da00bd6e1260e2002daca6cf72efd12b1ecefc5fee68d88cb'
```

Replace the example image reference with a real digest before rendering. The
renderer writes Kubernetes YAML into a new, empty output directory and prints
the namespace and Node label to use. It also writes `run-metadata.json` with
the image digest and source commit; commit the fixture before running a case
so that commit identifies the exact source:

```bash
python3 scripts/render-manifests.py \
  --case tc-014 --run-id "$RUN_ID" --image "$IMAGE_REF" \
  --output-dir /tmp/ocpstrat-2100-tc-014-verify01
```

Use `--case tc-012` and a different output directory for TC-012. The generated
namespace is `ocpstrat-2100-<case>-<run-id>`. Label **only** the intended guest
workers before applying the Deployment:

```bash
WORKER_1=replace-with-first-node-name
WORKER_2=replace-with-second-node-name
WORKER_3=replace-with-third-node-name
oc label node "$WORKER_1" "$WORKER_2" "$WORKER_3" \
  verification.hypershift.openshift.io/ocpstrat-2100-run="$RUN_ID"
```

Check that none of those Nodes already carries a different value for the
label. When the fourth TC-012 worker joins, apply the same label to it. A
returned Node may be a new Node object and need the label again. The label
controls test workload placement; it is not used to match VMs to Agents.

Apply the rendered namespace before namespaced objects. For TC-014:

```bash
export RENDERED_DIR=/tmp/ocpstrat-2100-tc-014-verify01
export TEST_NAMESPACE=ocpstrat-2100-tc-014-verify01
oc apply -f "$RENDERED_DIR/namespace.yaml"
oc apply -f "$RENDERED_DIR/service.yaml" -f "$RENDERED_DIR/deployment.yaml"
oc rollout status -n "$TEST_NAMESPACE" deployment/http-workload --timeout=10m
oc get pods -n "$TEST_NAMESPACE" -o wide
```

TC-014 must show three Ready server Pods on three distinct intended workers.
For TC-012, render with `--case tc-012` and apply the additional files:

```bash
export RENDERED_DIR=/tmp/ocpstrat-2100-tc-012-verify01
export TEST_NAMESPACE=ocpstrat-2100-tc-012-verify01
oc apply -f "$RENDERED_DIR/namespace.yaml"
oc apply -f "$RENDERED_DIR/service.yaml" -f "$RENDERED_DIR/deployment.yaml" \
  -f "$RENDERED_DIR/tc-012-pdb.yaml" -f "$RENDERED_DIR/tc-012-probes.yaml"
oc rollout status -n "$TEST_NAMESPACE" deployment/http-workload --timeout=10m
oc rollout status -n "$TEST_NAMESPACE" deployment/http-workload-probes --timeout=10m
oc get pods -n "$TEST_NAMESPACE" -o wide
oc get pdb -n "$TEST_NAMESPACE" http-workload
```

TC-012 starts with four Ready server Pods on three workers (2/1/1). After the
fourth Node joins, existing Pods do not rebalance automatically. Identify the
worker with two server Pods and evict one of them through the `policy/v1`
Eviction API. This respects the PDB; deleting the Pod directly would bypass
that check. Wait for four Ready server Pods on four distinct workers before
scaling the NodePool in. When the NodePool returns to four, repeat the
controlled eviction if a worker again has two server Pods.

## Request and probe checks

The server returns its Pod name, UID, Node name, namespace, and run ID from
`GET /identity`. To check the Service or an individual Pod from inside the
guest cluster, run a temporary probe Pod with the same image:

```bash
oc run -n "$TEST_NAMESPACE" one-shot-probe --rm -i --restart=Never \
  --image="$IMAGE_REF" --env="RUN_ID=$RUN_ID" --command -- \
  /workload probe --once --url=http://http-workload:8080/identity
```

For each server Pod, get its Pod IP and repeat with
`--url=http://<pod-ip>:8080/identity`. Use a different temporary Pod name if
the previous one has not yet been removed. Compare each returned Pod and Node
with `oc get pods -o wide`; a Service request alone may not visit every Pod.

For TC-012, start `scripts/watch-probes.sh "$TEST_NAMESPACE" <artifact-dir>`
in a separate terminal **before** scaling. It streams each probe Pod's logs
into JSON-line files, starts a new stream for replacement Pods, and records
Pod lifecycle and restart counts in `probe-lifecycle.jsonl`. Because the two
probes run on different workers, one stream survives removal of a single
worker. Each sample contains the serving Pod and Node, request status or
error, and latency. No retry hides an individual failure. The manifest uses a
two-second probe interval; evaluate each sampled interval for at least one
successful response from a surviving probe, and report any gaps alongside
`probe-lifecycle.jsonl`.

## Evidence and cleanup

Run the generic evidence collector at baseline, after scale-out, after
scale-in, and after reuse, using a different output directory each time:

```bash
scripts/collect-evidence.sh "$TEST_NAMESPACE" "$RUN_ID" \
  /tmp/ocpstrat-2100-evidence/baseline
```

It captures workload objects, EndpointSlices, events, labeled Nodes, Pod
placement, available Pod logs, and direct and Service `/identity` responses.
Review `request-results.tsv` for response identity checks. Capture VM, Agent,
Machine, and NodePool state separately for the test report. Save evidence
before deleting the namespace. For TC-012, stop `watch-probes.sh` with Ctrl-C
after the final snapshot and retain its output directory. Finally, remove the
namespace and the run label from all surviving test workers:

```bash
oc delete namespace "$TEST_NAMESPACE" --wait=true
for node in $(oc get nodes \
  -l verification.hypershift.openshift.io/ocpstrat-2100-run="$RUN_ID" \
  -o name); do
  oc label "$node" verification.hypershift.openshift.io/ocpstrat-2100-run-
done
```

The infrastructure procedure handles VM and Agent cleanup separately.
