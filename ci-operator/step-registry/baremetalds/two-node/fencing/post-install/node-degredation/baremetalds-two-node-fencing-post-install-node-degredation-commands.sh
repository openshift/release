#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
log() { echo "[$(date +'%F %T%z')] $*"; }

echo "baremetalds-two-node-fencing-post-install-node-degredation starting..."

ART_BASE="${ARTIFACT_DIR:-/tmp/artifacts}/degraded-two-node"
mkdir -p "${ART_BASE}"
KUBECONFIG="${SHARED_DIR}/kubeconfig"
export KUBECONFIG

if ! command -v oc >/dev/null 2>&1; then
	log "oc not found, installing client..."
	CLI_TAG_LOCAL="${CLI_TAG:-4.20}"
	UNAME_M="$(uname -m)"
	case "$UNAME_M" in
	x86_64) OC_TARBALL="openshift-client-linux.tar.gz" ;;
	aarch64 | arm64) OC_TARBALL="openshift-client-linux-arm64.tar.gz" ;;
	*)
		log "Unsupported arch: $UNAME_M"
		exit 1
		;;
	esac
	url="${OC_CLIENT_URL:-https://mirror.openshift.com/pub/openshift-v4/clients/ocp/candidate-${CLI_TAG_LOCAL}/${OC_TARBALL}}"
	mkdir -p /tmp/ocbin
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "$url" | tar -xz -C /tmp/ocbin oc
	else wget -qO- "$url" | tar -xz -C /tmp/ocbin oc; fi
	chmod +x /tmp/ocbin/oc || true
	export PATH="/tmp/ocbin:$PATH"
	hash -r
fi
oc version --client | tee "${ART_BASE}/oc-version.txt" || true

triage_imageregistry() {
  local label="${1:-manual}" ts outdir route_host jobname
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  outdir="${ART_BASE}/triage-imageregistry-${label}-${ts}"
  mkdir -p "$outdir"
  echo "== Triage (image-registry vs API) -> $outdir"

  # -----------------------------
  # Registry ground truth
  # -----------------------------
  oc get image.config/cluster -o yaml > "${outdir}/image-config.yaml" || true
  oc get co image-registry -o yaml > "${outdir}/co-image-registry.yaml" || true
  oc -n openshift-image-registry get deploy,rs,pod,svc,ep,route -o wide \
    > "${outdir}/imageregistry-objs.txt" 2>&1 || true

  # Route (optional)
  if oc -n openshift-image-registry get route default >/dev/null 2>&1; then
    oc -n openshift-image-registry describe route default \
      > "${outdir}/route-default-describe.txt" 2>&1 || true
    route_host="$(oc -n openshift-image-registry get route default -o jsonpath='{.status.ingress[0].host}' 2>/dev/null || true)"
  else
    route_host=""
    echo "No 'default' route (spec.defaultRoute false or not created)" > "${outdir}/route-default-describe.txt"
  fi

  # Registry deploy logs (optional)
  if oc -n openshift-image-registry get deploy image-registry >/dev/null 2>&1; then
    oc -n openshift-image-registry logs deploy/image-registry --all-containers --tail=-1 \
      > "${outdir}/imageregistry-logs.txt" 2>&1 || true
  else
    echo "Deployment image-registry not found" > "${outdir}/imageregistry-logs.txt"
  fi

  # -----------------------------
  # Direct dataplane probe to registry (/v2/) from inside cluster
  #   - run Job in 'default' ns (safer RBAC/SCC)
  # -----------------------------
  jobname="curl-registry-$(date -u +%H%M%S)"
  cat > "${outdir}/curl-job.yaml" <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${jobname}
  namespace: default
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: curl
        image: registry.access.redhat.com/ubi9/ubi
        env:
        - name: ROUTE_HOST
          value: "${route_host}"
        command: ["/bin/sh","-lc"]
        args:
        - |
          set -e
          echo "TIME=\$(date -u +%FT%TZ) POD->SVC"
          curl -k -sS -o /dev/null -w "%{http_code}\n" https://image-registry.openshift-image-registry.svc:5000/v2/ || true
          echo "TIME=\$(date -u +%FT%TZ) POD->ROUTE (\$ROUTE_HOST)"
          if [ -n "\$ROUTE_HOST" ]; then
            curl -k -sS -o /dev/null -w "%{http_code}\n" "https://\$ROUTE_HOST/v2/" || true
          else
            echo "no-route"
          fi
YAML

  oc apply -f "${outdir}/curl-job.yaml" >/dev/null 2>&1 || true
  if ! oc -n default wait --for=condition=complete "job/${jobname}" --timeout=180s >/dev/null 2>&1; then
    oc -n default get pods -l "job-name=${jobname}" -o wide > "${outdir}/curl-job-pods.txt" || true
  fi
  oc -n default logs "job/${jobname}" > "${outdir}/curl-probe.txt" 2>&1 || true
  oc -n default delete job "${jobname}" --ignore-not-found >/dev/null 2>&1 || true

  # -----------------------------
  # Control-plane health (KAS)
  # -----------------------------
  claim="$(oc get configs.imageregistry.operator.openshift.io/cluster -o jsonpath='{.spec.storage.pvc.claim}' 2>/dev/null || true)"
  [[ -z "${claim}" ]] && claim="image-registry-storage"

  # 2) PVC yaml + bound PV name
  oc -n openshift-image-registry get pvc "${claim}" -o yaml \
    > "${outdir}/pvc-${claim}.yaml" 2>/dev/null || echo "PVC ${claim} not found" > "${outdir}/pvc-${claim}.yaml"

  pv="$(oc -n openshift-image-registry get pvc "${claim}" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
  echo "${pv:-<unbound>}" > "${outdir}/pv-name.txt"

  # 3) PV topology: accessModes / storageClass / nodeAffinity (if any)
  if [[ -n "${pv}" ]]; then
    oc get pv "${pv}" -o yaml > "${outdir}/pv-${pv}.yaml" 2>/dev/null || true
    oc get pv "${pv}" -o yaml \
      | sed -n '/accessModes:/,/^$/p; /nodeAffinity:/,/^$/p; /storageClassName:/p' \
      > "${outdir}/pv-topology.txt" 2>/dev/null || true
  else
    echo "PVC not bound (no .spec.volumeName)" > "${outdir}/pv-topology.txt"
  fi

  # 4) Registry pod events (why Pending? multi-attach? node affinity?) + tolerations (unreachable eviction behavior)
  oc -n openshift-image-registry get pods -l docker-registry=default -o name \
    > "${outdir}/registry-pod-names.txt" 2>/dev/null || true
  while read -r rp; do
    [[ -z "$rp" ]] && continue
    oc -n openshift-image-registry describe "$rp" \
      > "${outdir}/describe-$(basename "$rp").txt" 2>/dev/null || true
  done < "${outdir}/registry-pod-names.txt"

  oc -n openshift-image-registry get pods -l docker-registry=default -o yaml \
    | sed -n '/tolerations:/,/^[^ ]/p' \
    > "${outdir}/registry-pod-tolerations.yaml" 2>/dev/null || true

  oc get co kube-apiserver -o yaml > "${outdir}/co-kas.yaml" || true
  oc -n openshift-kube-apiserver get pods -o wide > "${outdir}/kas-pods.txt" || true
  oc -n openshift-kube-apiserver get pod \
    -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount,PHASE:.status.phase,READY:.status.containerStatuses[*].ready \
    > "${outdir}/kas-restarts.txt" 2>/dev/null || true
  oc -n openshift-kube-apiserver get pods -o name > "${outdir}/kas-pod-names.txt" || true
  while read -r p; do
    [[ -z "$p" ]] && continue
    oc -n openshift-kube-apiserver logs "$p" --all-containers --tail=300 \
      > "${outdir}/kas-logs-$(basename "$p").txt" 2>&1 || true
  done < "${outdir}/kas-pod-names.txt"

  # Sample /readyz multiple times to catch transient unavailability
  for i in {1..10}; do
    echo "TIME=$(date -u +%FT%TZ)"
    oc get --raw /readyz?verbose || true
    sleep 2
  done > "${outdir}/kas-readyz-burst.txt" 2>&1

  # API endpoint object (for backend changes)
  oc -n default get endpointslices -l kubernetes.io/service-name=kubernetes -o yaml \
    > "${outdir}/kubernetes-endpointslice.yaml" 2>&1 || true
  oc -n default get endpoints kubernetes -o yaml \
    > "${outdir}/kubernetes-endpoints.yaml" 2>&1 || true

  # -----------------------------
  # Image controllers (imports/lookup run here)
  # -----------------------------
  oc get co openshift-controller-manager -o yaml > "${outdir}/co-ocm.yaml" || true
  oc -n openshift-controller-manager get pods -o wide > "${outdir}/ocm-pods.txt" || true
  oc -n openshift-controller-manager logs -l app=openshift-controller-manager --tail=800 --all-containers \
    > "${outdir}/ocm-logs-tail.txt" 2>&1 || true

  # -----------------------------
  # KAS operator + revisions (root-cause of NodeInstallerProgressing)
  # -----------------------------
  oc get kubeapiserver.operator.openshift.io/cluster -o yaml > "${outdir}/kas-operator.yaml" || true
  oc -n openshift-kube-apiserver get cm,secret -l openshift.io/revision -o name \
    | sort -V > "${outdir}/kas-revisioned-names.txt" 2>/dev/null || true
  oc get clusterversion version -o yaml > "${outdir}/clusterversion.yaml" || true

  # -----------------------------
  # Quick greps for common timeouts
  # -----------------------------
  egrep -ni 'timeout|deadline|connection reset|i/o timeout|context deadline|transport is closing' \
    "${outdir}"/kas-logs-*.txt "${outdir}/ocm-logs-tail.txt" "${outdir}/imageregistry-logs.txt" \
    > "${outdir}/timeouts-grep.txt" 2>/dev/null || true
}



snapshot_cluster() {
	local label="$1"
	local ts
	ts="$(date -u +%Y%m%dT%H%M%SZ)"
	local outdir="${ART_BASE}/${label}-${ts}"
	mkdir -p "${outdir}"

	echo "== Snapshot (${label}) -> ${outdir}"

	# 1) Image Registry config (yaml)
	oc get configs.imageregistry.operator.openshift.io/cluster -o yaml \
		>"${outdir}/imageregistry-config.yaml" || true

	# 2) Image Registry CO conditions (yaml tail from conditions:)
	oc get co image-registry -o yaml | sed -n '/^  conditions:/,$p' \
		>"${outdir}/image-registry-co-conditions.yaml" || true

	# 3) openshift-etcd Jobs (table)
	oc get jobs -n openshift-etcd \
		>"${outdir}/openshift-etcd-jobs.txt" || true

	# 4) All ClusterOperators wide
	oc get co -o wide \
		>"${outdir}/clusteroperators-wide.txt" || true

	# 5) etcd ClusterOperator (both wide & yaml for depth)
	oc get co etcd -o wide \
		>"${outdir}/co-etcd-wide.txt" || true
	oc get co etcd -o yaml \
		>"${outdir}/co-etcd.yaml" || true

	# Bonus: store oc get events around etcd/operator (optional; comment out if noisy)
	oc -n openshift-etcd get events --sort-by=.lastTimestamp \
		>"${outdir}/events-openshift-etcd.txt" || true
	oc -n openshift-etcd-operator get events --sort-by=.lastTimestamp \
		>"${outdir}/events-openshift-etcd-operator.txt" || true
}

# Check if DEGRADED_NODE is unset or empty
if [[ -z "${DEGRADED_NODE:-}" ]]; then
	echo "DEGRADED_NODE is not set, skipping node degradation"
	exit 0
fi

# Check if DEGRADED_NODE is set to "true"
if [[ "${DEGRADED_NODE}" != "true" ]]; then
	echo "DEGRADED_NODE is set to '${DEGRADED_NODE}', but not 'true', skipping node degradation"
	exit 0
fi

echo "DEGRADED_NODE is set to true, proceeding with node degradation..."

if [[ ! -e "${SHARED_DIR}/server-ip" ]]; then
	echo "No server IP found; skipping log gathering."
	exit 0
fi

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"
triage_imageregistry "pre-tests"

snapshot_cluster "before-degradation"

# SSH to the packet system and degrade the second node
echo "Connecting to packet system to degrade ostest_master_1..."

timeout -s 9 5m ssh "${SSHOPTS[@]}" "root@${IP}" bash - <<"EOF" |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'

set -xeo pipefail

set -o nounset
set -o errexit
set -o pipefail

echo "Connected to packet system, listing VMs..."
virsh -c qemu:///system list --all

echo "Looking for ostest_master_1 node..."
if virsh -c qemu:///system domstate ostest_master_1 >/dev/null 2>&1; then
    echo "Found ostest_master_1, proceeding with degradation..."

    #echo "Undefining ostest_master_1..."
    #virsh -c qemu:///system undefine ostest_master_1 --nvram|| true

    #echo "Destroying ostest_master_1..."
    #virsh -c qemu:///system destroy ostest_master_1 || true

    #echo "ostest_master_1 has been degraded (undefined and destroyed)"

    echo "Shutting down ostest_master_1..."
    virsh -c qemu:///system shutdown ostest_master_1 || true

    echo "Getting DHCP leases to find ostest_master_1 IP..."
    virsh -c qemu:///system net-dhcp-leases ostestbm

    # Extract ostest_master_0 IP address from DHCP leases
    MASTER0_IP=$(virsh -c qemu:///system net-dhcp-leases ostestbm | grep master-0 | awk '{print $5}' | cut -d'/' -f1)

    if [[ -z "${MASTER0_IP}" ]]; then
        echo "ERROR: Could not find ostest_master_0 IP address in DHCP leases"
        exit 1
    fi

    echo "Found ostest_master_0 IP: ${MASTER0_IP}"
    echo "Connecting to ostest_master_0 to run pcs commands..."

    # SSH to ostest_master_0 and run pcs commands
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 core@"${MASTER0_IP}" << 'MASTER0_EOF'

    echo "Connected to ostest_master_0, running pcs commands..."

    echo "Running: sudo pcs resource status"
    sudo pcs resource status

    echo "Running: sudo pcs property set stonith-enabled=false"
    sudo pcs property set stonith-enabled=false

    echo "Running: sudo pcs resource cleanup etcd"
    sudo pcs resource cleanup etcd

    echo "Running: sudo pcs resource status (final check)"
    sudo pcs resource status

    echo "pcs commands completed successfully on ostest_master_0"

MASTER0_EOF

    echo "Successfully ran pcs commands on ostest_master_0"

else
    echo "WARNING: ostest_master_1 not found or not accessible"
    virsh -c qemu:///system list --all
    exit 1
fi

echo "Current VM status after node degradation:"
virsh -c qemu:///system list --all

EOF
snapshot_cluster "after-degradation"
triage_imageregistry "post-degrade"

echo "Node degradation and pcs commands completed successfully"
