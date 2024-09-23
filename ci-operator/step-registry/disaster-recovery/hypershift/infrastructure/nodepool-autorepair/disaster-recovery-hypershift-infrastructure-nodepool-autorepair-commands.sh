#!/usr/bin/env bash

set -euxo pipefail

function delete_sts() {
    KUBECONFIG="${SHARED_DIR}"/nested_kubeconfig oc delete sts "$workload_name" -n "$workload_namespace"
    KUBECONFIG="${SHARED_DIR}"/nested_kubeconfig oc wait sts "$workload_name" -n "$workload_namespace" --for=delete --timeout=3m
}

function create_workload_on_nodes() {
    local nodes_for_workload=""
    local num_nodes_selected=""
    local volumes_attached=""

    nodes_for_workload="$(tr ' ' ',' <<< "$nodes_selected")"
    num_nodes_selected="$(wc -w <<< "$nodes_selected")"

    # Create workload that attaches volumes to the selected nodes
    trap delete_sts EXIT
    cat <<EOF | tee "${ARTIFACT_DIR}/hcp_autorepair_test_${workload_name}.yaml" | KUBECONFIG="${SHARED_DIR}"/nested_kubeconfig oc create -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: $workload_name
  namespace: $workload_namespace
spec:
  replicas: $num_nodes_selected
  selector:
    matchLabels:
      app: azure-disk
  template:
    metadata:
      labels:
        app: azure-disk
    spec:
      containers:
      - name: azure-disk-container
        image: busybox
        command: ["/bin/sh"]
        args: ["-c", "while true; do echo $(date) >> /mnt/azure-disk/data.txt; sleep 36000; done"]
        volumeMounts:
        - mountPath: /mnt/azure-disk
          name: azure-disk
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: kubernetes.io/hostname
                operator: In
                values: [$nodes_for_workload]
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchExpressions:
              - key: app
                operator: In
                values:
                - azure-disk
            topologyKey: "kubernetes.io/hostname"
  volumeClaimTemplates:
  - metadata:
      name: azure-disk
    spec:
      accessModes:
      - ReadWriteOnce
      storageClassName: "managed-csi"
      resources:
        requests:
          storage: 100Mi
EOF

    KUBECONFIG="${SHARED_DIR}"/nested_kubeconfig oc rollout status statefulset "$workload_name" -n "$workload_namespace" --timeout=5m

    for node in $nodes_selected; do
        volumes_attached=$(KUBECONFIG="${SHARED_DIR}"/nested_kubeconfig oc get node "$node" -o jsonpath='{.status.volumesAttached}')
        if [[ -z "$volumes_attached" ]]; then
            echo "No volume attached to node $node, exiting" >&2
            return 1
        fi
    done
}

function stop_kubelet_on_nodes() {
    local pids=()

    for node in $nodes_selected; do
        # Wait a few seconds for the debug pod to be running then stop kubelet on nodes
        { KUBECONFIG="${SHARED_DIR}/nested_kubeconfig" timeout 120s oc debug node/"$node" -- chroot /host bash -c "sleep 60; systemctl stop kubelet" || true; } &
        pids+=($!)
    done
    wait "${pids[@]}"
}

function wait_for_machine_deletion() {
    local pids=()

    for node in $nodes_selected; do
        { KUBECONFIG="${SHARED_DIR}/nested_kubeconfig" oc wait node "$node" --for=condition=ready=Unknown --timeout=5m; } &
        pids+=($!)
    done
    wait "${pids[@]}"

    pids=()
    for machine in $nodes_selected; do
        { oc wait machine "$machine" -n "$hcp_ns" --for=jsonpath='{.status.phase}'=Deleting --timeout=15m; } &
        pids+=($!)
    done
    wait "${pids[@]}"

    pids=()
    for machine in $nodes_selected; do
        { oc wait machine "$machine" -n "$hcp_ns" --for=delete --timeout=10m; } &
        pids+=($!)
    done
    wait "${pids[@]}"

    oc wait np "$np_selected" -n clusters --for=condition=Ready=False --timeout=5m
}

function wait_for_hc_recovery() {
    oc wait np -n clusters --all --for=condition=Ready=True --timeout=20m
    KUBECONFIG="${SHARED_DIR}"/nested_kubeconfig oc wait node --all --for=condition=Ready=True --timeout=5m
    KUBECONFIG="${SHARED_DIR}"/nested_kubeconfig oc wait co --all --for=condition=Available=True --timeout=10m
    KUBECONFIG="${SHARED_DIR}"/nested_kubeconfig oc wait co --all --for=condition=Progressing=False --timeout=10m
    KUBECONFIG="${SHARED_DIR}"/nested_kubeconfig oc wait co --all --for=condition=Degraded=False --timeout=10m
}

# Timestamp
export PS4='[$(date "+%Y-%m-%d %H:%M:%S")] '

# Check HC
hc="$(oc get hc -A -o jsonpath='{.items[0].metadata.name}')"
hcp_ns="clusters-$hc"

# Check NPs
nps="$(oc get np -A -o jsonpath='{.items[*].metadata.name}')"
nps_autorepair_arr=()
for np in $nps; do
    # Skip NPs with autoRepair disabled
    if [[ $(oc get np -n clusters "$np" -o jsonpath='{.spec.management.autoRepair}') != "true" ]]; then
        continue
    fi

    # Check condition
    if [[ $(oc get np -n clusters "$np" -o jsonpath='{.status.conditions[?(@.type=="AutorepairEnabled")].status}') != "True" ]]; then
        echo "NodePool $np has autorepair enabled but its AutorepairEnabled condition is not set to True, exiting" >&2
        exit 1
    fi
    nps_autorepair_arr+=("$np")
done
nps_autorepair_count="${#nps_autorepair_arr[@]}"
if (( nps_autorepair_count == 0 )); then
    echo "All NodePools have autorepair disabled, exiting" >&2
    exit 1
fi
np_selected="${nps_autorepair_arr[0]}"
nodes_selected="$(KUBECONFIG="${SHARED_DIR}/nested_kubeconfig" oc get node -l=hypershift.openshift.io/nodePool="$np_selected" -o jsonpath='{.items[*].metadata.name}')"
if [[ -z $nodes_selected ]]; then
    echo "NodePool $np_selected has no nodes, exiting" >&2
    exit 1
fi

# Check MHCs
mhcs="$(oc get mhc -A -o jsonpath='{.items[*].metadata.name}')"
mhc_count="$(wc -w <<< "$mhcs")"
if (( mhc_count != nps_autorepair_count )); then
    echo "Expect $nps_autorepair_count MHC, found $mhc_count: $mhcs, exiting" >&2
    exit 1
fi
mhc_selected="$np_selected"
max_unhealthy="$(oc get mhc "$mhc_selected" -n "$hcp_ns" -o jsonpath='{.spec.maxUnhealthy}')"

# Create workload
nodes_selected="$(cut -d ' ' -f 1-"$max_unhealthy" <<< "$nodes_selected")"
workload_name="${np}-sts"
workload_namespace=default
create_workload_on_nodes

stop_kubelet_on_nodes
wait_for_machine_deletion
wait_for_hc_recovery
