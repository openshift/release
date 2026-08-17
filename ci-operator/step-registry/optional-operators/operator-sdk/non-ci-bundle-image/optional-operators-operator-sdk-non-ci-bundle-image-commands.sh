#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "[$(date --utc +%FT%T.%3NZ)] == Parameters:"
echo "[$(date --utc +%FT%T.%3NZ)] OO_BUNDLE:            $OO_BUNDLE"
echo "[$(date --utc +%FT%T.%3NZ)] OO_INSTALL_NAMESPACE: $OO_INSTALL_NAMESPACE"
echo "[$(date --utc +%FT%T.%3NZ)] OO_INSTALL_MODE:      $OO_INSTALL_MODE"
echo "[$(date --utc +%FT%T.%3NZ)] OO_SECURITY_CONTEXT:  $OO_SECURITY_CONTEXT"
echo "[$(date --utc +%FT%T.%3NZ)] OO_PSA_ENFORCE_PRIVILEGED: $OO_PSA_ENFORCE_PRIVILEGED"
echo "[$(date --utc +%FT%T.%3NZ)] OO_MIRROR_TO_CLUSTER_REGISTRY: $OO_MIRROR_TO_CLUSTER_REGISTRY"
echo "[$(date --utc +%FT%T.%3NZ)] USE_HOSTED_KUBECONFIG:  $USE_HOSTED_KUBECONFIG"

if [[ "${USE_HOSTED_KUBECONFIG}" == "true" ]]; then
  export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
fi

if [[ -f "${SHARED_DIR}/operator-install-namespace.txt" ]]; then
    OO_INSTALL_NAMESPACE=$(cat "$SHARED_DIR"/operator-install-namespace.txt)
elif ! oc get namespace "$OO_INSTALL_NAMESPACE"; then
    echo "[$(date --utc +%FT%T.%3NZ)] OO_INSTALL_NAMESPACE is '$OO_INSTALL_NAMESPACE' which does not exist: creating"
    NS_NAMESTANZA="name: $OO_INSTALL_NAMESPACE"
else
    echo "[$(date --utc +%FT%T.%3NZ)] OO_INSTALL_NAMESPACE is '$OO_INSTALL_NAMESPACE'"
fi

echo "Checking/installing oc..."
if ! command -v oc &> /dev/null; then
    cd /tmp && curl -L https://openshift-mirror-list.ci-systems.workers.dev/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz -o oc.tar.gz && tar xzvf oc.tar.gz
fi
echo "Installing oc done"
./oc version --client

if [[ -n "${NS_NAMESTANZA:-}" ]]; then
    OO_INSTALL_NAMESPACE=$(
        ./oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: v1
kind: Namespace
metadata:
  $NS_NAMESTANZA
EOF
    )
fi

if [[ "${OO_INSTALL_NAMESPACE}" =~ ^openshift- ]] && [[ "${OO_PSA_ENFORCE_PRIVILEGED}" != "true" ]]; then
    echo "[$(date --utc +%FT%T.%3NZ)] Setting label security.openshift.io/scc.podSecurityLabelSync value to true on the namespace \"$OO_INSTALL_NAMESPACE\""
    ./oc label --overwrite ns "${OO_INSTALL_NAMESPACE}" security.openshift.io/scc.podSecurityLabelSync=true
else
    ./oc label --overwrite ns "${OO_INSTALL_NAMESPACE}" openshift.io/cluster-monitoring=true
    ./oc label --overwrite ns "${OO_INSTALL_NAMESPACE}" security.openshift.io/scc.podSecurityLabelSync=false pod-security.kubernetes.io/enforce=privileged
fi

OPTIONAL_ARGS=()
if [[ -n ${OO_INSTALL_MODE} ]]; then
  OPTIONAL_ARGS+=("--install-mode=${OO_INSTALL_MODE}")
fi

OO_BUNDLE_EFFECTIVE="${OO_BUNDLE}"

if [[ "${OO_MIRROR_TO_CLUSTER_REGISTRY}" == "true" ]]; then
    # operator-sdk run bundle pulls OO_BUNDLE via opm's own containerd-based
    # registry client, which cannot be given working credentials for some
    # external registries (observed against a CI registry proxy) even when
    # the same credential is independently valid via oc image mirror/oc
    # image info. Side-step this: mirror OO_BUNDLE into the test cluster's
    # own internal registry, grant anonymous pull there, and install from
    # that copy instead -- no credentials needed for operator-sdk's own
    # resolve step.
    #
    # Opt-in (default false): this ref is shared by non-KDM consumers (e.g.
    # openshift-file-integrity-operator) who don't need their cluster's
    # image-registry route exposed or an anonymous-pull grant added. Assumes
    # an ephemeral, single-use test cluster; none of these mutations are
    # torn down.
    echo "[$(date --utc +%FT%T.%3NZ)] Extracting the test cluster's own global pull secret to read OO_BUNDLE"
    # Cleanup net for every exit path (not just the happy path, which
    # already removes MERGED_AUTH_FILE promptly once oc image mirror is
    # done with it) -- these files hold the cluster's own global pull
    # secret and the mirror-destination credential, and an early `exit 1`
    # from any of the checks below would otherwise leave them in /tmp for
    # the rest of the pod's lifetime.
    trap 'rm -f /tmp/.dockerconfigjson /tmp/oo-merged-auth.json /tmp/oo-auth-splice.sed "${INSECURE_READ_ERR:-}"' EXIT
    (umask 077; ./oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm)
    echo "[$(date --utc +%FT%T.%3NZ)] Diagnostic: registries in pull secret: $(grep -oE '"[a-zA-Z0-9.-]+"[[:space:]]*:[[:space:]]*\{[[:space:]]*"auth"' /tmp/.dockerconfigjson | sed -E 's/^"([^"]+)".*/\1/' | paste -sd ', ' -)"

    echo "[$(date --utc +%FT%T.%3NZ)] Enabling the test cluster's own image registry default route"
    ./oc patch configs.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":true}}' --type=merge

    DEST_HOST=""
    for _ in $(seq 1 30); do
        DEST_HOST=$(./oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}' 2>/dev/null || true)
        [[ -n "${DEST_HOST}" ]] && break
        sleep 5
    done
    if [[ -z "${DEST_HOST}" ]]; then
        echo "[$(date --utc +%FT%T.%3NZ)] Timed out waiting for the image registry's default route" >&2
        exit 1
    fi
    echo "[$(date --utc +%FT%T.%3NZ)] Test cluster's own registry route: ${DEST_HOST}"

    # The bundle-unpack Job OLM creates for the Subscription pulls the bundle
    # image directly via kubelet/CRI-O, not operator-sdk's own HTTP client --
    # it has no --skip-tls-verify equivalent and does full TLS verification,
    # which fails against the registry route's self-signed certificate
    # ("x509: certificate signed by unknown authority"). Mark this route
    # hostname as an insecure registry cluster-wide (same pattern as this
    # repo's own quay-operator e2e test) so in-cluster pulls succeed.
    # Read-modify-write, not replace: this ref also mounts
    # openshift-custom-mirror-registry credentials for some consumers, who
    # may already have their own insecureRegistries entries that a blind
    # --type=merge replace on the array would discard.
    #
    # Known limitation: insecureRegistries disables TLS verification
    # entirely for this host; image.config.openshift.io/cluster's
    # spec.additionalTrustedCA would instead add the route's actual CA so
    # pulls stay verified. Narrower and strictly better, but needs its own
    # validation before swapping in.
    echo "[$(date --utc +%FT%T.%3NZ)] Marking ${DEST_HOST} as an insecure registry cluster-wide so in-cluster pulls (e.g. OLM's bundle-unpack Job) don't fail TLS verification against the registry route's own certificate"
    # Hard-fail (no `|| true`) rather than silently treating a failed read
    # as an empty list: the read-modify-write below exists specifically to
    # avoid discarding other consumers' entries, which a swallowed error
    # here would defeat -- a genuinely empty result and a failed query
    # must not be indistinguishable. stderr goes to a separate temp file,
    # not merged via 2>&1: a stray warning on an otherwise-successful call
    # would otherwise land inside EXISTING_INSECURE itself and get treated
    # as a real hostname by the substring check and array build below.
    INSECURE_READ_ERR=$(mktemp)
    if ! EXISTING_INSECURE=$(./oc get image.config.openshift.io/cluster -o jsonpath='{.spec.registrySources.insecureRegistries[*]}' 2>"${INSECURE_READ_ERR}"); then
        echo "[$(date --utc +%FT%T.%3NZ)] Failed to read the current insecureRegistries list; refusing to patch and risk dropping existing entries: $(cat "${INSECURE_READ_ERR}")" >&2
        rm -f "${INSECURE_READ_ERR}"
        exit 1
    fi
    rm -f "${INSECURE_READ_ERR}"
    # Only patch (and later wait for the MCO rollout it triggers) when
    # DEST_HOST is genuinely new. A no-op patch (host already present)
    # produces no new rendered MachineConfig, so the deterministic MCO
    # wait below would poll for a configuration.name change that never
    # comes and hang until its timeout -- this only bites a cluster whose
    # registrySources already lists the host (e.g. reused/pooled), not a
    # fresh IPI cluster where the array starts empty.
    if [[ " ${EXISTING_INSECURE} " != *" ${DEST_HOST} "* ]]; then
        NEW_INSECURE="${EXISTING_INSECURE:+${EXISTING_INSECURE} }${DEST_HOST}"
        # Intentional word splitting: one JSON array element per
        # space-separated host in NEW_INSECURE.
        # shellcheck disable=SC2086
        INSECURE_JSON=$(printf '"%s",' ${NEW_INSECURE})
        INSECURE_JSON="[${INSECURE_JSON%,}]"
        # Captured immediately before the patch, not after the several
        # steps (SA/token creation, mirroring) that follow -- capturing
        # it later risked the MCO already starting its rollout in that
        # gap, poisoning the "pre-change" baseline the wait below relies on.
        MCP_BASELINE=$(./oc get mcp -o jsonpath='{range .items[*]}{.metadata.name}={.status.configuration.name}{"\n"}{end}')
        if [[ -z "${MCP_BASELINE//[[:space:]]/}" ]]; then
            # No MachineConfigPools means the wait loop below would iterate
            # zero pools, leave ALL_DONE at its initial "true", and report
            # success on the very first attempt without confirming anything.
            echo "[$(date --utc +%FT%T.%3NZ)] No MachineConfigPools found; cannot confirm the insecure-registry trust rollout" >&2
            exit 1
        fi
        ./oc patch image.config.openshift.io/cluster --type=merge -p "{\"spec\":{\"registrySources\":{\"insecureRegistries\":${INSECURE_JSON}}}}"

        # Deterministic MCO rollout wait: nothing else in this
        # OO_MIRROR_TO_CLUSTER_REGISTRY block depends on the node-level
        # trust rollout except operator-sdk run bundle itself (much further
        # down), so running the wait immediately after the patch keeps the
        # baseline-to-first-poll gap as small as possible. Capture each
        # MCP's current rendered-config name before the patch (above), then
        # poll until every pool has moved to a different config AND
        # finished applying it to all its machines -- a plain
        # `oc wait --for=condition=Updated` can return instantly if the MCO
        # hasn't started rolling out yet (Updated can still read "True"
        # from before our own patch).
        echo "[$(date --utc +%FT%T.%3NZ)] Waiting for MachineConfigPools to finish rolling out the insecure-registry trust change"
        for _ in $(seq 1 90); do
            ALL_DONE=true
            DEGRADED_MCP=""
            while IFS='=' read -r mcp_name old_config; do
                [[ -z "${mcp_name}" ]] && continue
                new_config=$(./oc get mcp "${mcp_name}" -o jsonpath='{.status.configuration.name}' 2>/dev/null || true)
                updated_count=$(./oc get mcp "${mcp_name}" -o jsonpath='{.status.updatedMachineCount}' 2>/dev/null || true)
                total_count=$(./oc get mcp "${mcp_name}" -o jsonpath='{.status.machineCount}' 2>/dev/null || true)
                degraded_count=$(./oc get mcp "${mcp_name}" -o jsonpath='{.status.degradedMachineCount}' 2>/dev/null || true)
                # Default empty (not just failed) lookups too -- a pool
                # queried before its counts are populated returns "" with
                # exit 0, which `|| echo` alone wouldn't catch, and "" == ""
                # would have looked falsely "done".
                updated_count="${updated_count:-0}"
                total_count="${total_count:-1}"
                degraded_count="${degraded_count:-0}"
                if [[ "${degraded_count}" -gt 0 ]]; then
                    DEGRADED_MCP="${mcp_name}"
                fi
                if [[ "${new_config}" == "${old_config}" ]] || [[ "${updated_count}" != "${total_count}" ]]; then
                    ALL_DONE=false
                fi
            done <<< "${MCP_BASELINE}"
            if [[ -n "${DEGRADED_MCP}" ]]; then
                # Fail fast instead of burning the full wait budget: a
                # degraded pool isn't going to un-degrade on its own within
                # the remaining polls, so waiting out the rest of the 90
                # iterations only delays a failure that's already certain.
                echo "[$(date --utc +%FT%T.%3NZ)] MachineConfigPool ${DEGRADED_MCP} reports degraded machines; aborting the rollout wait early" >&2
                ./oc get mcp -o wide || true
                ./oc get nodes -o wide || true
                exit 1
            fi
            [[ "${ALL_DONE}" == "true" ]] && break
            sleep 20
        done
        if [[ "${ALL_DONE}" != "true" ]]; then
            # Fail here, with MCO-specific diagnostics, rather than warn and
            # proceed: without the trust rollout complete, the bundle-unpack
            # Job's pull fails TLS verification against DEST_HOST's
            # certificate anyway -- limping forward just defers to a later,
            # less diagnostic failure inside operator-sdk run bundle.
            echo "[$(date --utc +%FT%T.%3NZ)] MachineConfigPool rollout did not confirm completion within the wait budget" >&2
            ./oc get mcp -o wide || true
            ./oc get nodes -o wide || true
            exit 1
        fi
    else
        echo "[$(date --utc +%FT%T.%3NZ)] ${DEST_HOST} is already marked insecure -- skipping patch and MCO wait"
    fi

    # oc registry login needs the ambient session to be bearer-token-based,
    # but this test cluster's admin kubeconfig is client-cert based ("no
    # token is currently in use for this session"). Create a dedicated
    # ServiceAccount with explicit image-builder rights and a manually-
    # requested token Secret instead -- works regardless of the ambient
    # session's own credential type. Internal registry basic-auth accepts
    # any username with a valid SA token as the password (standard
    # OpenShift convention, e.g. `podman login -u unused -p $(oc whoami -t)`).
    OO_ROBOT_SA="oo-bundle-pusher"
    ./oc create serviceaccount "${OO_ROBOT_SA}" -n "${OO_INSTALL_NAMESPACE}" --dry-run=client -o yaml | ./oc apply -f -
    ./oc policy add-role-to-user system:image-builder -z "${OO_ROBOT_SA}" -n "${OO_INSTALL_NAMESPACE}"
    cat <<EOF | ./oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${OO_ROBOT_SA}-token
  namespace: ${OO_INSTALL_NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: ${OO_ROBOT_SA}
type: kubernetes.io/service-account-token
EOF

    ROBOT_TOKEN=""
    for _ in $(seq 1 30); do
        ROBOT_TOKEN=$(./oc get secret "${OO_ROBOT_SA}-token" -n "${OO_INSTALL_NAMESPACE}" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
        [[ -n "${ROBOT_TOKEN}" ]] && break
        sleep 2
    done
    if [[ -z "${ROBOT_TOKEN}" ]]; then
        echo "[$(date --utc +%FT%T.%3NZ)] Timed out waiting for the robot ServiceAccount token to populate" >&2
        exit 1
    fi

    # Built with printf/sed, not jq -- this ref has no guaranteed jq, and a
    # runtime curl download of an unpinned-by-checksum binary from an
    # archived repo isn't worth it for JSON this simple.
    # /tmp/.dockerconfigjson is a compact, machine-generated Secret extract
    # (oc extract, not hand-edited), so splicing a new entry right after
    # the opening "auths":{ is reliable.
    #
    # `|` as the sed delimiter, not `/`: a structural guarantee, not an
    # empirical one -- standard base64 (RFC 4648, DEST_AUTH_B64 below) uses
    # only A-Za-z0-9+/=, and a Route's .spec.host (DEST_HOST) is a DNS name
    # (RFC 1123: alphanumerics, hyphens, dots), so neither value spliced
    # through this sed can ever contain `|`.
    #
    # Script file, not an inline -e expression: an inline sed command puts
    # NEW_AUTH_ENTRY (which embeds the credential, base64-obscured but not
    # secret) on this process's own command line, visible to any other
    # process on the host via /proc/<pid>/cmdline for as long as sed runs.
    DEST_AUTH_B64=$(printf 'unused:%s' "${ROBOT_TOKEN}" | base64 | tr -d '\n')
    unset ROBOT_TOKEN
    MERGED_AUTH_FILE=/tmp/oo-merged-auth.json
    SED_SCRIPT=/tmp/oo-auth-splice.sed
    NEW_AUTH_ENTRY="\"${DEST_HOST}\":{\"auth\":\"${DEST_AUTH_B64}\"},"
    unset DEST_AUTH_B64
    (umask 077; printf 's|"auths"[[:space:]]*:[[:space:]]*\{|"auths":{%s|\n' "${NEW_AUTH_ENTRY}" > "${SED_SCRIPT}")
    (umask 077; sed -E -f "${SED_SCRIPT}" /tmp/.dockerconfigjson > "${MERGED_AUTH_FILE}")
    rm -f "${SED_SCRIPT}"
    if ! grep -q "\"${DEST_HOST}\":" "${MERGED_AUTH_FILE}"; then
        echo "[$(date --utc +%FT%T.%3NZ)] Failed to splice mirror credentials into the auth file" >&2
        exit 1
    fi

    # Generic name (not OADP-specific): this ref is shared by non-KDM
    # consumers too. Namespace-scoped and ephemeral, so no collision risk.
    OO_BUNDLE_MIRROR="${DEST_HOST}/${OO_INSTALL_NAMESPACE}/oo-bundle-mirror:latest"
    echo "[$(date --utc +%FT%T.%3NZ)] Mirroring ${OO_BUNDLE} to ${OO_BUNDLE_MIRROR}"
    # --insecure applies to BOTH ends of this single mirror invocation -- oc
    # image mirror has no per-registry insecure flag (see
    # `oc image mirror --help`) -- so it also skips TLS verification for
    # OO_BUNDLE's own source registry, not just DEST_HOST, which is the
    # only side that actually needs it. Known limitation, not an
    # oversight: splitting this into a verified pull (full TLS to the
    # source) followed by an insecure push (to DEST_HOST only), e.g. via a
    # local --dir stage, would close the gap, but needs its own validation
    # before swapping in.
    ./oc image mirror --registry-config="${MERGED_AUTH_FILE}" --filter-by-os=linux/amd64 --insecure=true "${OO_BUNDLE}=${OO_BUNDLE_MIRROR}"
    rm -f "${MERGED_AUTH_FILE}"
    OO_BUNDLE_EFFECTIVE="${OO_BUNDLE_MIRROR}"

    echo "[$(date --utc +%FT%T.%3NZ)] Granting anonymous pull on ${OO_INSTALL_NAMESPACE} so operator-sdk's own bundle-pull mechanism needs no credentials"
    # system:unauthenticated is a GROUP, not a user -- anonymous requests
    # authenticate as user system:anonymous, a member of that group.
    # add-role-to-USER never matches real anonymous requests ("access
    # denied" on an anonymous HEAD despite the binding existing:
    # www-authenticate="Basic realm=openshift,error=\"access denied\""),
    # so add-role-to-group is the correct subject kind.
    ./oc policy add-role-to-group system:image-puller system:unauthenticated -n "${OO_INSTALL_NAMESPACE}"

    # Deliberately NOT revoked once operator-sdk run bundle returns: the
    # CatalogSource OLM creates gets its own long-lived registry/grpc pod
    # (discoverable via -l olm.catalogSource, see the diagnostics below),
    # reconciled by OLM's catalog-operator for as long as the CatalogSource
    # exists -- i.e. for the rest of this job, well past this step's own
    # lifetime. If that pod is ever rescheduled (node pressure, eviction,
    # OOM) during set-related-image or e2e, kubelet re-pulls its image
    # from DEST_HOST, and revoking here first would turn that into an
    # ImagePullBackOff far from this step, with no obvious link back to
    # the cause.
    #
    # Leaving the grant standing for the rest of the job is acceptable
    # only because both of these hold: this is an ephemeral, single-use
    # test cluster torn down at job end, and this whole block only runs
    # when OO_MIRROR_TO_CLUSTER_REGISTRY is explicitly opted into (only
    # the 4 KDM configs, as of this writing). If either changes -- a
    # pooled or longer-lived cluster, or this flag ever defaulting to
    # true -- this reasoning needs revisiting.
    SKIP_TLS_VERIFY_ARG="--skip-tls-verify"
fi

if [[ -n "${SKIP_TLS_VERIFY_ARG:-}" ]]; then
  OPTIONAL_ARGS+=("${SKIP_TLS_VERIFY_ARG}")
fi

set +o errexit
(
  cd /tmp
  # ${OPTIONAL_ARGS[@]+"${OPTIONAL_ARGS[@]}"}, not a bare
  # "${OPTIONAL_ARGS[@]}": expanding a zero-element array under
  # set -o nounset only stopped erroring in bash 4.4+. bash 3.2 (still
  # the macOS system default, and plausible in other minimal base
  # images) hard-errors ("unbound variable") on the bare form for an
  # empty array; this guarded form works on both.
  operator-sdk run bundle "${OO_BUNDLE_EFFECTIVE}" -n "${OO_INSTALL_NAMESPACE}" --verbose "${OPTIONAL_ARGS[@]+"${OPTIONAL_ARGS[@]}"}" --timeout="${OO_INSTALL_TIMEOUT_MINUTES}m" --security-context-config="${OO_SECURITY_CONTEXT}"
)
RUN_BUNDLE_STATUS=$?
set -o errexit

if [[ "${RUN_BUNDLE_STATUS}" -ne 0 ]]; then
    # A generic timeout here can mask a real OLM-side blocker rather than
    # just slow resync/resolution -- dump the actual state so it's
    # diagnosable instead of guessed at.
    echo "[$(date --utc +%FT%T.%3NZ)] operator-sdk run bundle failed (exit ${RUN_BUNDLE_STATUS}) -- dumping OLM diagnostics"
    ./oc get catalogsource -n "${OO_INSTALL_NAMESPACE}" -o yaml || true
    ./oc get subscription -n "${OO_INSTALL_NAMESPACE}" -o yaml || true
    ./oc get installplan -n "${OO_INSTALL_NAMESPACE}" -o yaml || true
    ./oc get pods -n "${OO_INSTALL_NAMESPACE}" -o wide || true
    REG_POD=$(./oc get pods -n "${OO_INSTALL_NAMESPACE}" -l olm.catalogSource -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "${REG_POD}" ]]; then
        echo "[$(date --utc +%FT%T.%3NZ)] Logs for registry pod ${REG_POD}"
        ./oc logs "${REG_POD}" -n "${OO_INSTALL_NAMESPACE}" --all-containers || true
    fi
    ./oc get events -n "${OO_INSTALL_NAMESPACE}" --sort-by=.lastTimestamp || true
    ./oc get pods -n openshift-operator-lifecycle-manager -o wide || true
    exit "${RUN_BUNDLE_STATUS}"
fi

echo "check deployment"
if [[ ! -z "${DEPLOYMENT}" ]]; then
    ./oc wait --timeout=10m --for condition=Available -n openshift-file-integrity deployment $DEPLOYMENT
fi
echo "[$(date --utc +%FT%T.%3NZ)] Script Completed Execution Successfully !"
