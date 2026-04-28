#!/bin/bash
# abi-install-bmc — Agent-based installer **install** phase (BMC / virtual media; **install** phase).
#
# **Chisel:** OpenShift Secret `test-credentials/chisel-creds` is mounted at `/secret/chisel`.
# Basic-auth filenames use the `chisel-usr--…` / `chisel-pwd--…` pattern (suffix from `OCP__ABI__TEAM_NAME`).
#
# Logic in this Step:
# - `agent create image` -> ISO is served via HTTP Server `8080` (Range-aware) + **Chisel** reversed tunnel.
# - Redfish boot loop: mount ISO + boot nodes (order from `ocp--bmc--info.json`) + conditional disk wipe (BMC: pre-boot, OS: post-boot via SSH).
# - `wait-for bootstrap-complete` -> copy minimal `KUBECONFIG` -> **Day-1.5** (runs concurrently with `wait-for install-complete`).
# - `wait-for install-complete` -> eject virtual media.
# - **Day-2**: Nodes Ready -> `OCP__ABI__DAY2_SCRIPTS_YAML` scripts for custom post-deployment actions.
# - HTTP Server + **Chisel** torn down by `EXIT` trap.
#
set -euxo pipefail
shopt -s inherit_errexit

eval "$(
    curl -fsSL "https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/main/libs/bash/common/BuildCustomScriptsFromYAML.sh"
)"


typeset bmcInfo="${SHARED_DIR}/ocp--bmc--info.json"; [ -f "${bmcInfo}" ]
typeset isoFile='' isoURL='' chiselCrdUsr='' chiselCrdPwd=''
typeset -i httpSvcPort=8080
typeset -ai taskPIDs=()
export OCP__ABI__CFG="${CLUSTER_PROFILE_DIR}/ocp--abi--cfg.yaml"; [ -r "${OCP__ABI__CFG}" ]


function openshift-install () {
    typeset -i es=0
    {
        echo \
"$(date -Iseconds)|${FUNCNAME[0]@Q} ${*@Q}"$'\n'"$(printf '%.0s-' {1..80})"
        command openshift-install \
            --dir "${OCP__ABI__CLUSTER_DIR}/" \
            --log-level "${OCP__ABI__INSTLR_LOG_LEVEL}" \
            "$@" 2>&1 || es=$?
        echo "$(printf '%.0s=' {1..80})"
        ((! es))
    } | tee -a "${ARTIFACT_DIR}/ocp--installer--cluster.log"
    ((! PIPESTATUS[0]))
}

function RedfishAPIcall () {
    typeset bmcInfo="${1:?}"; (($#)) && shift
    typeset bmcURL="${1:?}"; (($#)) && shift
    typeset apiMethod="${1:?}"; (($#)) && shift
    typeset apiEP="${1?}"; (($#)) && shift
    curl -sSLk -X "${apiMethod}" \
        --fail-with-body \
        -K <(
            set +x
            jq -r \
                --arg url "${bmcURL}" \
                '
                    .[] |
                    select(.url == $url) |
                    "-u \("\(.usr):\(.pwd)" | @json)"
                ' \
            0< "${bmcInfo}"
        ) \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json' \
        "$@" \
        "${bmcURL}/redfish/v1/${apiEP#/}"
    true
}

function VCD-Eject () {
    typeset bmcInfo="${1:?}"; (($#)) && shift
    typeset bmcURL="${1:?}"; (($#)) && shift
    typeset bmcMgrId="${1:?}"; (($#)) && shift
    RedfishAPIcall "${bmcInfo}" "${bmcURL}" POST \
        "Managers/${bmcMgrId}/VirtualMedia/CD/Actions/VirtualMedia.EjectMedia" \
        -d '{}' || true
    true
}

function Host-PowerControl () {
    typeset bmcInfo="${1:?}"; (($#)) && shift
    typeset bmcURL="${1:?}"; (($#)) && shift
    typeset bmcSysId="${1:?}"; (($#)) && shift
    typeset resetType="${1:?}"; (($#)) && shift
    RedfishAPIcall "${bmcInfo}" "${bmcURL}" POST \
        "Systems/${bmcSysId}/Actions/ComputerSystem.Reset" \
        -d "{\"ResetType\": \"${resetType}\"}"
    true
}

function WipeDisks () {
    typeset -i tPID="${1:?}"; (($#)) && shift
    typeset bmcInfo="${1:?}"; (($#)) && shift
    typeset bmcURL="${1:?}"; (($#)) && shift
    typeset bmcSysId="${1:?}"; (($#)) && shift
    typeset bmcMgrId="${1:?}"; (($#)) && shift
    typeset wipeMethod="${1?}"; (($#)) && shift
    case ${wipeMethod} in
      (OS) (
        typeset hostIPv4
        hostIPv4="$(jq -r \
            --arg url "${bmcURL}" \
            '.[] | select(.url == $url).hostIPv4' \
        0< "${bmcInfo}")"
        typeset -i es=0
        while true; do
            kill -0 "${tPID}" 2>/dev/null || break
            sleep 30
            es=0
            ssh -n \
                -o UserKnownHostsFile=/dev/null \
                -o StrictHostKeyChecking=no \
                -o ConnectTimeout=5 \
                -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey" \
                "core@${hostIPv4}" \
                "$(cat - 0<<'sshEOF'
sudo bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'shEOF'
    typeset dev=
    grep -qE '\bcoreos\.live(\.|iso=)' /proc/cmdline || exit 193
    udevadm settle
    while IFS= read -r dev; do
        sgdisk --zap-all "${dev}"
        wipefs -a "${dev}"
        blkdiscard "${dev}" 2> /dev/null || true
    done 0< <(
        lsblk -dpno NAME,TYPE | awk '($2 == "disk"){print $1}'
    )
    true
shEOF
)"
sshEOF
                    )" || es=$?
            case ${es} in
              (0)   break ;;
              (193) exit ${es} ;;
            esac
        done
      ) ;;
      (BMC) (
        typeset ctrlId='' volEP='' driveEP='' jobId=''
        typeset -a jobIds=()
        while IFS= read -r ctrlId; do
            while IFS= read -r volEP; do
                # Try `Volume.Initialize`.
                jobId="$(
                    RedfishAPIcall "${bmcInfo}" "${bmcURL}" POST \
                        "${volEP#/redfish/v1/}/Actions/Volume.Initialize" \
                        -d '{
                            "InitializeType": "Slow",
                            "@Redfish.OperationApplyTime": "OnReset"
                        }' -o /dev/null -w '%header{location}'
                )" || true
                jobId="${jobId##*/}"
                [ -n "${jobId}" ] && jobIds+=("${jobId}") && continue
                # Fallback to `SecureErase` the Volume's Physical Drives.
                while IFS= read -r driveEP; do
                    jobId="$(
                        RedfishAPIcall "${bmcInfo}" "${bmcURL}" POST \
                            "${driveEP#/redfish/v1/}/Actions/Drive.SecureErase" \
                            -d '{}' -o /dev/null -w '%header{location}'
                    )" || true
                    jobId="${jobId##*/}"
                    [ -n "${jobId}" ] && jobIds+=("${jobId}")
                done 0< <(
                    RedfishAPIcall "${bmcInfo}" "${bmcURL}" GET \
                        "${volEP#/redfish/v1/}" |
                    jq -r '.Links.Drives[]?."@odata.id" // empty'
                )
            done 0< <(
                RedfishAPIcall "${bmcInfo}" "${bmcURL}" GET \
                    "Systems/${bmcSysId}/Storage/${ctrlId}/Volumes" |
                jq -r '.Members[]?."@odata.id" // empty'
            )
        done 0< <(
            RedfishAPIcall "${bmcInfo}" "${bmcURL}" GET \
                "Systems/${bmcSysId}/Storage" |
            jq -r '.Members[]."@odata.id" | split("/")[-1]'
        )
        # Restart Host.
        Host-PowerControl "${bmcInfo}" "${bmcURL}" "${bmcSysId}" ForceRestart
        # Wait for all wipe Jobs to complete.
        while true; do
            kill -0 "${tPID}" 2>/dev/null || break
            sleep 60
            for jobId in "${jobIds[@]}"; do
                {
                    RedfishAPIcall "${bmcInfo}" "${bmcURL}" GET \
                        "Managers/${bmcMgrId}/Jobs/${jobId}" |
                    jq -e '
                        .JobState | test("^Completed"; "i")
                    '
                } && {
                    RedfishAPIcall "${bmcInfo}" "${bmcURL}" DELETE \
                        "Managers/${bmcMgrId}/Jobs/${jobId}" ||
                    true
                } || continue 2
            done
            break
        done
      ) ;;
      ('')  ;;
      (*)   : "Unknown method: ${wipeMethod}"; false;;
    esac
    true
}


# Chisel basic auth (disable `xtrace` while reading secrets).
set +x
chiselCrdUsr="$(cat "/secret/chisel/chisel-usr--${OCP__ABI__TEAM_NAME}")"
chiselCrdPwd="$(cat "/secret/chisel/chisel-pwd--${OCP__ABI__TEAM_NAME}")"
set -x

trap '
    ((${#taskPIDs[@]})) && {
        kill "${taskPIDs[@]}" 2>/dev/null || true
        wait "${taskPIDs[@]}" 2>/dev/null || true
    }
' EXIT

# Restore OCP Installation information from previous Step.
mkdir -p "${OCP__ABI__CLUSTER_DIR}"
tar zxf "${SHARED_DIR}/ocpClusterInf.tgz" -C "${OCP__ABI__CLUSTER_DIR}/"
rm -f "${SHARED_DIR}/ocpClusterInf.tgz"

# Chisel / ISO URL (Job Conf. YAML key `.tests[*].steps.env`); fail before `agent create image`.
[ -n "${OCP__ABI__TUN_SVC__DP_BASE_URL}" ] && [ -n "${OCP__ABI__TUN_SVC__DP_PORT}" ] && [ -n "${OCP__ABI__TUN_SVC__CP_URL}" ]

# ISO Creation Phase.
openshift-install agent create image
isoFile="$(
    shopt -s nullglob
    echo "${OCP__ABI__CLUSTER_DIR}"/agent.*.iso
)"
[ -f "${isoFile}" ]
isoURL="${OCP__ABI__TUN_SVC__DP_BASE_URL%%/}/${OCP__ABI__TUN_SVC__DP_PORT}/${isoFile##*/}"

# Local HTTP serves the ISO (`HTTP Range` required by some BMC / virtual-media stacks); `ARTIFACT_DIR` holds logs.
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
        hdrs = ''.join(f'  {k}: {v}\n' for k, v in self.headers.items())
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
} 1> "${ARTIFACT_DIR}/ocp--installer--httpd.log" 2>&1 & taskPIDs+=($!)

# Chisel reverse tunnel (CI has no ingress to the test pod).
set +x
chisel client \
    --auth "${chiselCrdUsr}:${chiselCrdPwd}" \
    "${OCP__ABI__TUN_SVC__CP_URL%%/}/" \
    "R:0.0.0.0:${OCP__ABI__TUN_SVC__DP_PORT}:localhost:${httpSvcPort}" \
    1> "${ARTIFACT_DIR}/ocp--installer--chisel.log" 2>&1 & taskPIDs+=($!)
set -x

# Probe BMC-facing ISO URL over the tunnel (HTTP `HEAD`). `sleep` before `curl` so the Chisel reverse tunnel can finish coming up.
(
    typeset -i tryLeft=5
    while ((tryLeft)); do
        sleep 5
        curl -fsSL -I -o /dev/null \
            --connect-timeout 2 --max-time 5 \
            "${isoURL}" && break
        ((tryLeft--))
    done
    ((tryLeft))
)

# Reboot Nodes into OCP Agent Installation ISO.
({
    typeset bmcURL='' bmcVend='' bmcSysId='' bmcMgrId=''
    typeset diskWipeMethod=''
    typeset -i tryLeft=0
    typeset -i myPID="${BASHPID}"
    typeset -i tPID
    tPID="$(ps -o ppid= -p "${myPID}")"
    while IFS= read -r bmcURL; do
        # Auto-discover BMC Vendor and Identifiers.
        bmcVend=$(
            RedfishAPIcall "${bmcInfo}" "${bmcURL}" GET '' |
            jq -r '.Vendor // "Unknown"'
        )
        bmcSysId=$(
            RedfishAPIcall "${bmcInfo}" "${bmcURL}" GET 'Systems' |
            jq -r '.Members[0]["@odata.id"] | split("/")[-1]'
        )
        bmcMgrId=$(
            RedfishAPIcall "${bmcInfo}" "${bmcURL}" GET 'Managers' |
            jq -r '.Members[0]["@odata.id"] | split("/")[-1]'
        )

        # Vendor-specific preparation.
        case ${bmcVend} in
          (Dell)
            # Ignore Cert. on `.RFS.1` (VirtualMedia/CD).
            RedfishAPIcall "${bmcInfo}" "${bmcURL}" PATCH \
                "Managers/${bmcMgrId}/Attributes" \
                -d '{"Attributes": {"RFS.1.IgnoreCertWarning": "Yes"}}'
            ;;
          (*)   false;;
        esac

        # Ensure booting to ISO.
        tryLeft=3
        while ((tryLeft)); do
            kill -0 "${tPID}" 2>/dev/null || break

            # Eject previously mounted media.
            VCD-Eject "${bmcInfo}" "${bmcURL}" "${bmcMgrId}"
            # Set Boot Order.
            {
                # Try to set to VCD for wiping Disks via Host OS.
                diskWipeMethod=OS
                RedfishAPIcall "${bmcInfo}" "${bmcURL}" PATCH \
                    "Systems/${bmcSysId}" \
                    -d '{"Boot": {
                        "BootSourceOverrideEnabled": "Continuous",
                        "BootSourceOverrideTarget": "Cd"
                    }}'
            } || {
                # Fallback to wiping Disks via BMC.
                diskWipeMethod=''
                WipeDisks "${tPID}" "${bmcInfo}" \
                    "${bmcURL}" "${bmcSysId}" "${bmcMgrId}" \
                    BMC
            }
            # Mount ISO.
            RedfishAPIcall "${bmcInfo}" "${bmcURL}" POST \
                "Managers/${bmcMgrId}/VirtualMedia/CD/Actions/VirtualMedia.InsertMedia" \
                -d "$(
                    jq -cnr \
                        --arg img "${isoURL}" \
                        '{
                            "Image": $img,
                            "TransferProtocolType": "HTTPS",
                            "TransferMethod": "Stream"
                        }'
                )"
            # Set boot `Once` if BMC Wipe (`Continuous` not supported).
            [ -n "${diskWipeMethod}" ] || {
                RedfishAPIcall "${bmcInfo}" "${bmcURL}" PATCH \
                    "Systems/${bmcSysId}" \
                    -d '{"Boot": {
                        "BootSourceOverrideEnabled": "Once",
                        "BootSourceOverrideTarget": "Cd"
                    }}'
            }
            # Restart Host.
            Host-PowerControl "${bmcInfo}" "${bmcURL}" "${bmcSysId}" ForceRestart
            # Wipe Disks via Host OS (no-op for BMC Wipe).
            WipeDisks "${tPID}" "${bmcInfo}" \
                "${bmcURL}" "${bmcSysId}" "${bmcMgrId}" \
                "${diskWipeMethod}" && break || true
            ((tryLeft--))
        done
        ((tryLeft))
        # Restore Boot Order.
        [ -z "${diskWipeMethod}" ] || {
            RedfishAPIcall "${bmcInfo}" "${bmcURL}" PATCH \
                "Systems/${bmcSysId}" \
                -d '{"Boot": {
                    "BootSourceOverrideEnabled": "Disabled",
                    "BootSourceOverrideTarget": "None"
                }}'
        }
    done < <(jq -r '
        .[] | .url
    ' 0< "${bmcInfo}")
} |& tee "${ARTIFACT_DIR}/ocp--installer--bmc.log") & taskPIDs+=($!)
# Wait for BootStrap Node to finish.
(
    typeset -i tryLeft="${OCP__ABI__WAIT__BOOTSTRAP__H}"
    while ((tryLeft)); do
        openshift-install agent wait-for bootstrap-complete && break
        ((tryLeft--))
    done
    ((tryLeft))
)
cp -f "${OCP__ABI__CLUSTER_DIR}/auth/kubeconfig" "${SHARED_DIR}/kubeconfig-minimal"

# Day-1.5 Phase.
(
    typeset cfgKey='' cfgVal=''
    export KUBECONFIG="${OCP__ABI__CLUSTER_DIR}/auth/kubeconfig"
    while IFS=$'\t' read -r cfgKey cfgVal; do
        case ${cfgKey} in
          (NodeProv)
            [ "${cfgVal}" = false ] && {
                # Workers are provisioned by ABI. No
                #   BareMetalHost CRDs or Ironic
                #   provisioning network.
                while true; do
                    oc -n openshift-machine-api \
                        scale MachineSets \
                        --replicas 0 --all \
                    && break || sleep 60
                done
            }
            ;;
        esac
    done 0< <(
        yq -o json eval '
            ."Day1.5".config // []
        ' "${OCP__ABI__CFG}" |
        jq -r '
            .[] | to_entries[] |
            [.key, (.value | tostring)] | join("\t")
        '
    )
    true
) & taskPIDs+=($!)
# Wait for OCP installation to complete (`install-complete` can be slow with many workers).
(
    typeset -i tryLeft="${OCP__ABI__WAIT__CLUSTER__H}"
    while ((tryLeft)); do
        openshift-install agent wait-for install-complete && break
        ((tryLeft--))
    done
    ((tryLeft))
)

# Eject virtual media on all nodes (ISO no longer needed after install).
while IFS= read -r bmcURL; do
    VCD-Eject "${bmcInfo}" "${bmcURL}" "$(
        RedfishAPIcall "${bmcInfo}" "${bmcURL}" GET 'Managers' |
        jq -r '.Members[0]["@odata.id"] | split("/")[-1]'
    )"
done < <(jq -r '.[] | .url' 0< "${bmcInfo}")

# Collect cluster authentication artifacts.
tar zcf "${ARTIFACT_DIR}/ocp.tgz" -C "${OCP__ABI__CLUSTER_DIR}/" auth/
cp -f "${OCP__ABI__CLUSTER_DIR}/auth/kube"{config,admin-password} "${SHARED_DIR}/"

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
[ -f "${KUBECONFIG}" ]

# TODO: Update secret store with `KUBECONFIG`.

# Ensure Nodes readiness before Day-2 customization.
oc wait node --all --for=condition=Ready --timeout=300s

# Post-Deployment Customization.
eval "$(BuildCustomScriptsFromYAML OCP__ABI__DAY2_SCRIPTS_YAML)"
