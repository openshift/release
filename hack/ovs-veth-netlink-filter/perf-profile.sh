#!/usr/bin/env bash
set -euo pipefail

run_dir=/run/ovs-veth-filter
output_dir=/var/tmp/ovs-veth-filter-perf
pid_file=$run_dir/perf.pid
stop_file=$run_dir/perf.stop-requested

: "${NODE_NAME:?NODE_NAME must be set}"
: "${OVS_PERF_NODES:=}"
: "${OVS_PERF_DURATION_SECONDS:=2700}"
: "${OVS_PERF_FREQUENCY:=19}"
: "${OVS_PERF_STACK_BYTES:=2048}"

mkdir -p "$run_dir" "$output_dir"
rm -f "$pid_file" "$stop_file"

case ",$OVS_PERF_NODES," in
    *,"$NODE_NAME",*) ;;
    *)
        echo "perf profiling disabled on unselected node $NODE_NAME"
        exec sleep infinity
        ;;
esac

for value in "$OVS_PERF_DURATION_SECONDS" "$OVS_PERF_FREQUENCY" \
    "$OVS_PERF_STACK_BYTES"; do
    if [[ ! $value =~ ^[1-9][0-9]*$ ]]; then
        echo "invalid positive perf setting: $value" >&2
        exit 1
    fi
done

while true; do
    ovs_pid=$(pidof ovs-vswitchd 2>/dev/null | awk '{ print $1 }')
    [[ -n $ovs_pid ]] && break
    echo "waiting for ovs-vswitchd before starting perf" >&2
    sleep 5
done

started=$(date +%s)
base=$output_dir/ovs-perf-${NODE_NAME}-${started}-${ovs_pid}
data_file=$base.data
meta_file=$base.meta
log_file=$base.log
perf_pid=

stop_perf()
{
    if [[ -n $perf_pid ]] && kill -0 "$perf_pid" 2>/dev/null; then
        echo "stopping perf process $perf_pid"
        kill -INT "$perf_pid" 2>/dev/null || true
        wait "$perf_pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
}
trap stop_perf EXIT
trap 'exit 0' INT TERM

{
    echo "node=$NODE_NAME"
    echo "ovs_pid=$ovs_pid"
    echo "ovs_exe=$(readlink /proc/$ovs_pid/exe)"
    echo "kernel=$(uname -r)"
    echo "perf_version=$(perf version)"
    echo "perf_event_paranoid=$(cat /proc/sys/kernel/perf_event_paranoid)"
    echo "started_epoch=$started"
    echo "duration_seconds=$OVS_PERF_DURATION_SECONDS"
    echo "frequency_hz=$OVS_PERF_FREQUENCY"
    echo "call_graph=dwarf,$OVS_PERF_STACK_BYTES"
} > "$meta_file"

perf record -e cpu-clock -F "$OVS_PERF_FREQUENCY" \
    --call-graph "dwarf,$OVS_PERF_STACK_BYTES" -p "$ovs_pid" \
    -o "$data_file" -- sleep "$OVS_PERF_DURATION_SECONDS" \
    > "$log_file" 2>&1 &
perf_pid=$!
echo "$perf_pid" > "$pid_file"
echo "started perf recording on $NODE_NAME for ovs-vswitchd pid $ovs_pid as process $perf_pid"

sleep 2
if ! kill -0 "$perf_pid" 2>/dev/null; then
    wait "$perf_pid" || true
    cat "$log_file" >&2
    echo "perf exited before the bounded recording interval" >&2
    exit 1
fi

set +e
wait "$perf_pid"
status=$?
set -e
perf_pid=
rm -f "$pid_file"
stopped_by_gather=false
if [[ -e $stop_file ]]; then
    stopped_by_gather=true
    rm -f "$stop_file"
fi
{
    echo "finished_epoch=$(date +%s)"
    echo "perf_exit_status=$status"
    echo "stopped_by_gather=$stopped_by_gather"
    echo "perf_data_bytes=$(stat -c %s "$data_file" 2>/dev/null || echo 0)"
} >> "$meta_file"
cat "$log_file"
echo "perf recording finished on $NODE_NAME with status $status"

# Keep the DaemonSet container alive so the gather step can collect its files.
exec sleep infinity
