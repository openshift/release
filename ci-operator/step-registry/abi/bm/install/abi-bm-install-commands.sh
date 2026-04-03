#!/bin/bash
# abi-bm-install — Agent-based installer **install** phase (bare metal).
#
# Unpacks **`${SHARED_DIR}/ocpClusterInf.tgz`** into **OCP__ABI__CLUSTER_DIR**, runs **`openshift-install agent create image`**, serves the ISO
# with local HTTP + mandatory Chisel, drives Redfish from **`bmc--info.json`**, **`wait-for bootstrap-complete`** / **`install-complete`**,
# copies **kubeconfig** / **kubeadmin-password** and **`${ARTIFACT_DIR}/ocp.tgz`**, then nodes Ready, **OCP__ABI__DAY2_SCRIPTS_YAML** (cluster health is checked by **`cucushift-installer-check-cluster-health`** in the workflow test phase, not here).
# ISO / tunnel / Redfish narrative: **`../../README.md`** (**abi-bm-install** section).
#
# **Chisel:** OpenShift Secret **`test-credentials/chisel-creds`** is mounted at **`/secret/chisel`**. Basic-auth filenames use the **`chisel-usr--…`** / **`chisel-pwd--…`** pattern (suffix from **`OCP__ABI__TEAM_NAME`** in **`abi-bm-install-ref.yaml`**).
#
# Step input parameters: **`abi-bm-install-ref.yaml`** (`env` entries; step registry docs). Set via Job Conf. YAML **.tests[*].steps.env**. **DAY0** / **DAY1** script YAML are **abi-bm-conf** only.
#
# Logic in this Step:
# - **`ocpClusterInf.tgz`** -> **`agent create image`** -> HTTP **:8080** (stdlib server with **Range** support) + **Chisel** (HTTPS) -> **Redfish** (**`bmc--info.json`** only) -> **`wait-for bootstrap-complete`** / **`install-complete`** -> **kubeconfig** / **ocp.tgz** / **kubeadmin-password** -> **SHARED_DIR** (**ARTIFACT_DIR** for **ocp.tgz**).
# - **Day-2**: **`KUBECONFIG`** under cluster dir for **`oc`** -> **nodes** Ready -> **OCP__ABI__DAY2_SCRIPTS_YAML**. Post-install cluster health (incl. ClusterOperators) is left to **`cucushift-installer-check-cluster-health`** in the job workflow. HTTP + **Chisel** are torn down by the **EXIT** trap when the step finishes (no explicit kill).
#
set -euxo pipefail
shopt -s inherit_errexit

eval "$(
    curl -fsSL "https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/main/libs/bash/common/BuildCustomScriptsFromYAML.sh"
)"

typeset isoFile='' isoURL='' chiselCrdUsr='' chiselCrdPwd=''
typeset -i httpSvcPort=8080
typeset -ai svcPIDs=()

function RedfishAPIcall () {
    typeset bmcURL="${1:?}"
    (($#)) && shift
    typeset apiMethod="${1:?}"
    (($#)) && shift
    # Empty **apiEP** → service root **GET** (e.g. **Vendor**); **${1:-}** keeps **nounset** safe when the path is **''**.
    typeset apiEP="${1:-}"
    (($#)) && shift

    curl -sSLk -X "${apiMethod}" \
        --fail-with-body \
        -K <(
            set +x
            # **curl --config** (-K) uses its own token/quoting rules — not shell **@sh**; **@json** emits a safe **-u** argument for the config file.
            jq -r \
                --arg url "${bmcURL}" \
                '
                    .[] |
                    select(.url == $url) |
                    "-u " + ((.usr + ":" + .pwd) | @json)
                ' \
                0< "${OCP__ABI__CLUSTER_DIR}/bmc--info.json"
        ) \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json' \
        "$@" \
        "${bmcURL}/redfish/v1/${apiEP#/}"
    true
}

function openshift-install () {
    command openshift-install \
        --dir "${OCP__ABI__CLUSTER_DIR}/" \
        --log-level "${OCP__ABI__INSTLR_LOG_LEVEL}" \
        "$@"
    true
}

# Chisel basic auth (disable **xtrace** while reading secrets).
set +x
chiselCrdUsr="$(cat "/secret/chisel/chisel-usr--${OCP__ABI__TEAM_NAME}")"
chiselCrdPwd="$(cat "/secret/chisel/chisel-pwd--${OCP__ABI__TEAM_NAME}")"
set -x

trap '((${#svcPIDs[@]})) && kill "${svcPIDs[@]}" 2>/dev/null || true' EXIT

# Restore install workspace from **abi-bm-conf** (then drop tarball from **SHARED_DIR**).
mkdir -p "${OCP__ABI__CLUSTER_DIR}"
tar zxf "${SHARED_DIR}/ocpClusterInf.tgz" -C "${OCP__ABI__CLUSTER_DIR}/"
rm -f "${SHARED_DIR}/ocpClusterInf.tgz"

# Chisel / ISO URL (Job Conf. YAML key **.tests[*].steps.env**); fail before **`agent create image`**.
[ -n "${OCP__ABI__TUN_SVC__DP_BASE_URL}" ] && [ -n "${OCP__ABI__TUN_SVC__DP_PORT}" ] && [ -n "${OCP__ABI__TUN_SVC__CP_URL}" ]

# **agent.*.iso** path after **`openshift-install agent create image`** (nullglob in subshell; rely on **errexit** / prior success).
openshift-install agent create image
isoFile="$(
    shopt -s nullglob
    echo "${OCP__ABI__CLUSTER_DIR}"/agent.*.iso
)"
[ -f "${isoFile}" ]
isoURL="${OCP__ABI__TUN_SVC__DP_BASE_URL%%/}/${OCP__ABI__TUN_SVC__DP_PORT}/${isoFile##*/}"

# Local HTTP serves the ISO (**HTTP Range** required by some BMC / virtual-media stacks); **ARTIFACT_DIR** holds logs.
{
    python3 - "${httpSvcPort}" "${OCP__ABI__CLUSTER_DIR}" 0<<'pyEOF'
import functools
import http.server
import os
import shutil
import sys
from datetime import datetime, timezone


class RangeHandler(http.server.SimpleHTTPRequestHandler):
    def send_head(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path):
            return super().send_head()
        try:
            f = open(path, 'rb')
        except OSError:
            self.send_error(404)
            return None
        fs = os.fstat(f.fileno())
        size = fs.st_size
        ctype = self.guess_type(path)
        rng = self.headers.get('Range', '')
        start, end = 0, size - 1
        if rng.startswith('bytes='):
            try:
                s, e = rng[6:].split('-', 1)
                start = int(s) if s else 0
                end = int(e) if e else size - 1
            except ValueError:
                f.close()
                self.send_error(400)
                return None
            end = min(end, size - 1)
            if start > end:
                f.close()
                self.send_error(416)
                return None
            f.seek(start)
            self._copy_length = end - start + 1
            self.send_response(206)
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        else:
            self._copy_length = None
            self.send_response(200)
        length = end - start + 1
        self.send_header('Content-type', ctype)
        self.send_header('Content-Length', str(length))
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Last-Modified', self.date_time_string(fs.st_mtime))
        self.end_headers()
        return f

    def copyfile(self, source, outputfile):
        try:
            remaining = getattr(self, '_copy_length', None)
            if remaining is not None:
                self._copy_length = None
                buf = shutil.COPY_BUFSIZE
                while remaining > 0:
                    data = source.read(min(buf, remaining))
                    if not data:
                        break
                    outputfile.write(data)
                    remaining -= len(data)
            else:
                super().copyfile(source, outputfile)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, fmt, *args):
        hdrs = ''.join(f' {k}: {v}\n' for k, v in self.headers.items())
        sys.stderr.write(
            f'[{datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}] {fmt % args}\n'
            f'{hdrs}'
        )
        sys.stderr.flush()


http.server.test(
    HandlerClass=functools.partial(
        RangeHandler,
        directory=(sys.argv[2] if len(sys.argv) > 2 else '.'),
    ),
    port=int(sys.argv[1]) if len(sys.argv) > 1 else 8080,
    bind='0.0.0.0',
)
pyEOF
} 1> "${ARTIFACT_DIR}/httpd.log" 2>&1 & svcPIDs+=($!)

# Chisel reverse tunnel (CI has no ingress to the test pod).
set +x
chisel client \
    --auth "${chiselCrdUsr}:${chiselCrdPwd}" \
    "${OCP__ABI__TUN_SVC__CP_URL%%/}/" \
    "R:0.0.0.0:${OCP__ABI__TUN_SVC__DP_PORT}:localhost:${httpSvcPort}" \
    1> "${ARTIFACT_DIR}/chisel.log" 2>&1 & svcPIDs+=($!)
set -x

# Probe BMC-facing ISO URL over the tunnel (**HEAD**). **sleep** before **curl** so Chisel can finish the reverse tunnel; **-k** temporarily allows **HTTPS** by IP (until BMC firmware/TLS is aligned).
typeset -i tryLeft=5
while (( tryLeft )); do
    sleep 5
    curl -fsSLk -I -o /dev/null --connect-timeout 2 --max-time 5 "${isoURL}" && break
    (( tryLeft-- ))
done
(( tryLeft ))

[ -f "${OCP__ABI__CLUSTER_DIR}/bmc--info.json" ]

# Reboot nodes into the OCP install ISO
while read -r bmcURL; do
    # Auto-discover BMC vendor and Redfish identifiers.
    typeset bmcVend bmcSysId bmcMgrId
    bmcVend="$(
        RedfishAPIcall "${bmcURL}" GET '' |
            jq -r '.Vendor // "Unknown"'
    )"
    bmcSysId="$(
        RedfishAPIcall "${bmcURL}" GET 'Systems' |
            jq -r '.Members[0]["@odata.id"] | split("/")[-1]'
    )"
    bmcMgrId="$(
        RedfishAPIcall "${bmcURL}" GET 'Managers' |
            jq -r '.Members[0]["@odata.id"] | split("/")[-1]'
    )"

    # Vendor-specific preparation (Dell iDRAC: allow HTTPS ISO when cert warnings apply). Service root **Vendor** is a short manufacturer id per Redfish (null → **Unknown** above).
    case "${bmcVend}" in
        (Dell)
            RedfishAPIcall "${bmcURL}" PATCH \
                "Managers/${bmcMgrId}/Attributes" \
                -d '{"Attributes": {"RFS.1.IgnoreCertWarning": "Yes"}}'
            ;;
        (*)
            false
            ;;
    esac

    # Eject previously mounted media, then mount ISO (**Stream** + **HTTPS**).
    RedfishAPIcall "${bmcURL}" POST \
        "Managers/${bmcMgrId}/VirtualMedia/CD/Actions/VirtualMedia.EjectMedia" \
        -d '{}' || true
    # **InsertMedia** is blocking on tested BMCs (no poll for **Inserted**; rely on **curl --fail-with-body** / step failure).
    RedfishAPIcall "${bmcURL}" POST \
        "Managers/${bmcMgrId}/VirtualMedia/CD/Actions/VirtualMedia.InsertMedia" \
        -d "$(
            jq -cnr \
                --arg img "${isoURL}" \
                '{"Image": $img, "TransferProtocolType": "HTTPS", "TransferMethod": "Stream"}'
        )"

    # Set boot order.
    RedfishAPIcall "${bmcURL}" PATCH \
        "Systems/${bmcSysId}" \
        -d '{"Boot": {"BootSourceOverrideEnabled": "Once", "BootSourceOverrideTarget": "Cd"}}'

    # Power cycle the system.
    RedfishAPIcall "${bmcURL}" POST \
        "Systems/${bmcSysId}/Actions/ComputerSystem.Reset" \
        -d '{"ResetType": "ForceRestart"}'
done < <(jq -r '.[] | .url' 0< "${OCP__ABI__CLUSTER_DIR}/bmc--info.json")

# Wait for bootstrap ( **`openshift-install agent wait-for bootstrap-complete`** is ~1h per attempt; loop for slow BM).
(
    typeset -i tryLeft="${OCP__ABI__WAIT__BOOTSTRAP__H}"
    while ((tryLeft)); do
        openshift-install agent wait-for bootstrap-complete && break
        ((tryLeft--))
    done
    ((tryLeft))
)
cp -f "${OCP__ABI__CLUSTER_DIR}/auth/kubeconfig" "${SHARED_DIR}/kubeconfig-minimal"

# Wait for OCP installation to complete (**install-complete** can be slow with many workers).
(
    typeset -i tryLeft="${OCP__ABI__WAIT__CLUSTER__H}"
    while ((tryLeft)); do
        openshift-install agent wait-for install-complete && break
        ((tryLeft--))
    done
    ((tryLeft))
)

# Eject virtual media on all nodes (ISO no longer needed after install).
while read -r bmcURL; do
    RedfishAPIcall "${bmcURL}" POST \
        "Managers/$(
            RedfishAPIcall "${bmcURL}" GET 'Managers' |
                jq -r '.Members[0]["@odata.id"] | split("/")[-1]'
        )/VirtualMedia/CD/Actions/VirtualMedia.EjectMedia" \
        -d '{}' || true
done < <(jq -r '.[] | .url' 0< "${OCP__ABI__CLUSTER_DIR}/bmc--info.json")

# Collect cluster authentication artifacts.
tar zcf "${ARTIFACT_DIR}/ocp.tgz" -C "${OCP__ABI__CLUSTER_DIR}/" auth/
cp -f "${OCP__ABI__CLUSTER_DIR}/auth/kube"{config,admin-password} "${SHARED_DIR}/"

export KUBECONFIG="${OCP__ABI__CLUSTER_DIR}/auth/kubeconfig"
[ -f "${KUBECONFIG}" ]

# Ensure node readiness before Day-2 customization (**KUBECONFIG** under cluster **auth/**, not **SHARED_DIR**).
oc wait node --all --for=condition=Ready --timeout=300s

# Post-Deployment Customization.
eval "$(BuildCustomScriptsFromYAML OCP__ABI__DAY2_SCRIPTS_YAML)"
