#!/bin/bash
# rosa-seaplane-e2e-env — resolve the e2e environment into e2e.env (ROSAENG-75288).
#
# Writes a plain KEY=value file to ${SHARED_DIR}/e2e.env so the parallel
# suite runner (rosa-seaplane-e2e-run) and the suites it invokes never
# read Terraform outputs or pin files directly.
#
# Contents (no secrets — AWS credentials stay in the mounted secret):
#   E2E_SRC_API / E2E_SRC_ZOA / E2E_SRC_ROSA_CLI   pinned suite commits
#   BASE_URL, RHOBS_API_URL, ZOA_RC_API_URL, ZOA_MC_API_URL,
#   ZOA_DEPLOYMENT_NAME, CLUSTER_PREFIX, OCP_IMAGE, AWS_DEFAULT_REGION
#
# Pin resolution (P4): pins are read from the rosa-seaplane commit that was
# PROVISIONED (rosa-seaplane-source.env / rosa-seaplane-sha in SHARED_DIR),
# i.e. before CI overrides pins with ci-tags — so tests match what is
# deployed, not what the PR under test changed.
#
# Readiness: fails with "environment not ready" unless the platform API
# answers and (when customer credentials are mounted) they work and the
# customer account is allowlisted — replacing the old per-suite gating.

set -euo pipefail

CREDS_DIR="${CREDS_DIR:-/var/run/rosa-credentials}"
E2E_ENV="${SHARED_DIR}/e2e.env"
AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"

# ---------------------------------------------------------------------------
# 1. Resolve the provisioned rosa-seaplane commit (pins are read from it).
# ---------------------------------------------------------------------------
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

PLATFORM_URL="https://github.com/openshift-online/rosa-seaplane.git"
PLATFORM_SHA=""
SOURCE_ENV="${SHARED_DIR}/rosa-seaplane-source.env"
if [[ -r "${SOURCE_ENV}" ]]; then
  # shellcheck source=/dev/null
  source "${SOURCE_ENV}" # sets REPOSITORY_URL and PINNED_SHA
  PLATFORM_URL="${REPOSITORY_URL}"
  PLATFORM_SHA="${PINNED_SHA}"
  echo "Using provisioned rosa-seaplane commit: ${PLATFORM_URL}@${PLATFORM_SHA}"
elif [[ -r "${SHARED_DIR}/rosa-seaplane-sha" ]]; then
  PLATFORM_SHA="$(cat "${SHARED_DIR}/rosa-seaplane-sha")"
  echo "Using rosa-seaplane-sha: ${PLATFORM_SHA}"
else
  # Standing environments (int/stage) are not provisioned by this workflow
  # and supply neither shared file. Pins MUST resolve from the deployed
  # commit: fail when no explicit ref is configured — silently falling
  # back to main could run tests that do not match what is deployed.
  if [[ -z "${ROSA_REGIONAL_PLATFORM_REF:-}" ]]; then
    echo "ERROR: no provisioned rosa-seaplane commit found and ROSA_REGIONAL_PLATFORM_REF is unset — set it to the deployed commit SHA (required for standing environments)" >&2
    exit 1
  fi
  PLATFORM_SHA="${ROSA_REGIONAL_PLATFORM_REF}"
  echo "Using ROSA_REGIONAL_PLATFORM_REF=${PLATFORM_SHA} for pin resolution (standing environment)"
fi

# ---------------------------------------------------------------------------
# 2. Resolve environment endpoints.
#    Ephemeral: Terraform outputs in SHARED_DIR. Standing: creds files.
# ---------------------------------------------------------------------------
TF_OUTPUTS="${SHARED_DIR}/regional-terraform-outputs.json"
TF_MC_OUTPUTS="${SHARED_DIR}/management-terraform-outputs.json"

resolve_url() { # <value-name> <tf-file> <tf-key> <creds-file>
  local name="$1" tf_file="$2" tf_key="$3" creds_file="$4" value=""
  if [[ -n "${!name:-}" ]]; then
    return 0 # caller-provided value wins
  elif [[ -r "${CREDS_DIR}/${creds_file}" ]]; then
    value="$(cat "${CREDS_DIR}/${creds_file}")"
  elif [[ -n "${tf_file:-}" && -r "${tf_file}" ]]; then
    value="$(jq -r "${tf_key} // empty" "${tf_file}")"
  fi
  [[ -n "${value}" ]] && export "${name}=${value}"
  # Optional endpoints may legitimately be absent: return success so the
  # caller's set -e does not abort the step (required values are validated
  # separately below).
  return 0
}

resolve_url BASE_URL            "${TF_OUTPUTS}"    '.api_gateway_invoke_url.value' api_url
resolve_url RHOBS_API_URL       "${TF_OUTPUTS}"    '.rhobs_api_url.value'           rhobs_api_url
resolve_url ZOA_RC_API_URL      "${TF_OUTPUTS}"    '.zoa_api_function_url.value'    zoa_rc_api_url
resolve_url ZOA_MC_API_URL      "${TF_MC_OUTPUTS}" '.zoa_api_function_url.value'    zoa_mc_api_url
resolve_url ZOA_DEPLOYMENT_NAME "${TF_OUTPUTS}"    '.deployment_name.value'         zoa_deployment_name

if [[ -z "${BASE_URL:-}" ]]; then
  echo "ERROR: could not resolve BASE_URL — environment not ready" >&2
  exit 1
fi

# Cluster prefix: caller-provided wins; standing envs use bare names; ephemeral
# derives eph-<hash>- from BUILD_ID (same rule as before-suites.sh).
if [[ -z "${CLUSTER_PREFIX:-}" ]]; then
  if [[ -r "${CREDS_DIR}/api_url" ]]; then
    CLUSTER_PREFIX=""
  elif [[ -n "${BUILD_ID:-}" ]]; then
    CLUSTER_PREFIX="eph-$(echo -n "${BUILD_ID}" | sha256sum | cut -c1-6)-"
  fi
fi
export CLUSTER_PREFIX

# OCP image: resolved by rosa-seaplane-resolve-ocp-image when present.
if [[ -z "${OCP_IMAGE:-}" && -r "${SHARED_DIR}/ocp-image" ]]; then
  OCP_IMAGE="$(cat "${SHARED_DIR}/ocp-image")"
fi
export OCP_IMAGE="${OCP_IMAGE:-}"

# ---------------------------------------------------------------------------
# 3. Resolve suite pins from the provisioned rosa-seaplane commit.
#    Reads ci/e2e-hooks/suite-repos.yaml at PLATFORM_SHA (P4: before CI
#    overrides). Config-file pins resolve like the deployment (P1): config
#    keys from the rendered merged config at that commit; ArgoCD values from
#    the base values.yaml (env layers of the provisioned commit).
# ---------------------------------------------------------------------------
git init -q "${WORK_DIR}/platform"
git -C "${WORK_DIR}/platform" fetch -q --depth 1 "${PLATFORM_URL}" "${PLATFORM_SHA}"
git -C "${WORK_DIR}/platform" checkout -q FETCH_HEAD

python3 - "${WORK_DIR}/platform" "${E2E_ENVIRONMENT:-}" "${E2E_REGION:-}" > "${WORK_DIR}/pins.env" <<'PYEOF'
import sys
from pathlib import Path

import yaml

platform = Path(sys.argv[1])
env_filter = sys.argv[2] or None
region_filter = sys.argv[3] or None
registry = yaml.safe_load(
    (platform / "ci/e2e-hooks/suite-repos.yaml").read_text()
)["suites"]


# Select the rendered merged config(s) for the provisioned environment:
# E2E_ENVIRONMENT/E2E_REGION narrow to one; otherwise all env dirs are used
# and must agree on the pin value (they share config/defaults.yaml).
env_dirs = sorted(
    d for d in (platform / "deploy").glob("*/*")
    if (d / "_merged_config.yaml").is_file()
)
if env_filter:
    env_dirs = [d for d in env_dirs if d.parent.name == env_filter]
if region_filter:
    env_dirs = [d for d in env_dirs if d.name == region_filter]
if not env_dirs:
    print("E2E_PIN_ERROR_ENV='no matching deploy/<env>/<region>/_merged_config.yaml'")
    sys.exit(0)


def dig(data, dotted):
    cur = data
    for part in dotted.split("."):
        cur = cur[part]
    return cur


def resolve_config_pin(source):
    values = set()
    for env_dir in env_dirs:
        merged = yaml.safe_load(
            (env_dir / "_merged_config.yaml").read_text()
        )
        values.add(str(dig(merged, source["key"])))
    if len(values) != 1:
        raise KeyError(
            f"pin resolves differently across environments: {sorted(values)}"
        )
    return values.pop()


def merged_overlay(base, overlay):
    out = dict(base)
    for k, v in overlay.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = merged_overlay(out[k], v)
        else:
            out[k] = v
    return out


def resolve_argocd_pin(source, env_dirs):
    """ArgoCD pins resolve like the deployment: base values overlaid by the
    environment's argocd-values-* layer (layer wins), so a stage override
    of an image tag is honored. All selected environments must agree."""
    values = set()
    for env_dir in env_dirs:
        base = yaml.safe_load((platform / source["file"]).read_text())
        for layer_path in sorted(env_dir.glob("argocd-values-*.yaml")):
            overlay = yaml.safe_load(layer_path.read_text())
            if overlay:
                base = merged_overlay(base, overlay)
        values.add(str(dig(base, source["key"])))
    if len(values) != 1:
        raise KeyError(f"argocd pin differs across environments: {sorted(values)}")
    return values.pop()


for suite, cfg in sorted(registry.items()):
    for pin in cfg.get("pins", []):
        source = pin.get("source", {})
        try:
            if "ref" in pin:
                value = pin["ref"]
            elif source["file"].startswith("config/"):
                value = resolve_config_pin(source)
            else:
                value = resolve_argocd_pin(source, env_dirs)
        except (KeyError, FileNotFoundError) as exc:
            print(f"E2E_PIN_ERROR_{suite}_{pin['name']}='unresolved: {exc}'")
            continue
        print(f"E2E_PIN_{suite}_{pin['name']}='{value}'")
        # Preserve the pin type: ref pins (explicit branch refs) are resolved
        # differently from legacy image tags — a tag like 'zoa-2026.11' must
        # not be queried as a branch name.
        if "ref" in pin:
            print(f"E2E_PINREF_{suite}='{value}'")
PYEOF

if grep -q "^E2E_PIN_ERROR_" "${WORK_DIR}/pins.env"; then
  echo "ERROR: could not resolve some suite pins from ${PLATFORM_SHA}:" >&2
  grep "^E2E_PIN_ERROR_" "${WORK_DIR}/pins.env" >&2
  exit 1
fi
cat "${WORK_DIR}/pins.env"

# Map suites to their pinned commit. Selection rules:
#   1. Collect every pin value carrying a full 40-char SHA (stripping any
#      @sha256:<digest> suffix). If several, pick the DESCENDANT-MOST one
#      (newest pin wins — tests match the newest deployed component), via
#      ancestry checks in a blobless clone of the suite repo.
#   2. If no SHA pins exist and the suite has a `ref:` pin, resolve THAT
#      ref (`git ls-remote refs/heads/<ref>`) — a `ref: seaplane-v2` pin
#      must not silently resolve to the default branch (master for
#      openshift/rosa).
#   3. Otherwise (waived legacy image tags, e.g. zoa's short Konflux tags)
#      fall back to the default branch HEAD, matching today's behavior.
suite_commit() { # <suite> <repo-url>
  local suite="$1" repo="$2" value
  local -a shas=()
  while IFS= read -r value; do
    value="${value%%@*}" # strip @sha256:<digest>
    [[ "${value}" =~ ^[0-9a-f]{40}$ ]] && shas+=("${value}")
  done < <(grep "^E2E_PIN_${suite}_" "${WORK_DIR}/pins.env" \
    | sed -e "s/^E2E_PIN_${suite}_[^=]*='//" -e "s/'$//")
  if [[ ${#shas[@]} -gt 0 ]]; then
    if [[ ${#shas[@]} -eq 1 ]]; then
      echo "${shas[0]}"
      return
    fi
    # Newest pin wins: resolve the descendant-most SHA among the candidates.
    # Fetch from the repo URL directly (git init does not configure an
    # 'origin' remote), and deepen the history when ancestry is inconclusive
    # before declaring the pins divergent — a shallow fetch can miss the
    # connecting history when pins are far apart.
    local clone="${WORK_DIR}/${suite}.git"
    git init -q "${clone}"
    git -C "${clone}" fetch -q --no-tags --depth 50 "${repo}" "${shas[@]}"
    local newest="" a b
    for _ in 1 2 3; do
      newest=""
      for a in "${shas[@]}"; do
        local is_newest=true
        for b in "${shas[@]}"; do
          [[ "${a}" == "${b}" ]] && continue
          git -C "${clone}" merge-base --is-ancestor "${b}" "${a}" || is_newest=false
        done
        if [[ "${is_newest}" == true ]]; then
          newest="${a}"
          break
        fi
      done
      [[ -n "${newest}" ]] && break
      # Ancestry inconclusive on this depth: deepen (or unshallow) and retry.
      git -C "${clone}" fetch -q --deepen=500 "${repo}" "${shas[@]}" 2>/dev/null \
        || git -C "${clone}" fetch -q --unshallow "${repo}" 2>/dev/null || true
    done
    if [[ -z "${newest}" ]]; then
      echo "ERROR: ${suite} pins are on diverging histories (${shas[*]}) — cannot determine the newest pin" >&2
      return 1
    fi
    echo "${newest}"
    return
  fi
  # No SHA pins: use the suite's EXPLICIT ref pin (E2E_PINREF_, emitted only
  # for registry `ref:` pins) — never a legacy image tag, which would be
  # queried as a nonexistent branch and yield an empty commit.
  local ref_pin
  ref_pin="$(sed -n "s/^E2E_PINREF_${suite}='//p" "${WORK_DIR}/pins.env" | sed "s/'$//" | head -1)"
  if [[ -n "${ref_pin}" ]]; then
    echo "WARNING: no full-SHA pin for ${suite} — resolving ref pin '${ref_pin}'" >&2
    local resolved
    resolved="$(git ls-remote "${repo}" "refs/heads/${ref_pin}" | cut -f1)"
    if [[ -z "${resolved}" ]]; then
      echo "ERROR: ref pin '${ref_pin}' for ${suite} did not resolve to a commit" >&2
      return 1
    fi
    echo "${resolved}"
    return
  fi
  echo "WARNING: no full-SHA pin for ${suite} — falling back to default branch HEAD" >&2
  git ls-remote "${repo}" HEAD | cut -f1
}

E2E_SRC_API="$(suite_commit api https://github.com/openshift-online/rosa-seaplane-api.git)"
E2E_SRC_ZOA="$(suite_commit zoa https://github.com/openshift-online/rosa-seaplane-zoa.git)"
E2E_SRC_ROSA_CLI="$(suite_commit rosa-cli https://github.com/openshift/rosa.git)"

# ---------------------------------------------------------------------------
# 4. Readiness check — fail here so no suite starts.
#    A signed call with the RC profile on a cheap read route, requiring a
#    2xx: an unsigned request only proves DNS + the gateway exist (an
#    IAM-authorized route returns 403 from the gateway itself even when
#    the platform API behind it is down). This check replaces the old
#    "only run the rest if platform-api passed" gating, so it must
#    actually reach the API.
# ---------------------------------------------------------------------------
export AWS_CONFIG_FILE="${AWS_CONFIG_FILE:-${CREDS_DIR}/aws_config}"
if [[ -r "${AWS_CONFIG_FILE}" ]]; then
  if ! AWS_PROFILE=rrp-rc awscurl --service execute-api --region "${AWS_DEFAULT_REGION}" \
      --fail-with-body -X GET "${BASE_URL}/api/v0/clusters" -o /dev/null 2>/dev/null; then
    echo "ERROR: platform API at ${BASE_URL} is not healthy (signed GET /api/v0/clusters failed) — environment not ready" >&2
    exit 1
  fi
  echo "Platform API healthy (signed GET /api/v0/clusters succeeded)"
else
  # No AWS credentials mounted: fall back to the unsigned gateway probe so
  # the step still fails fast on a missing environment.
  http_code="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' "${BASE_URL}/api/v0/clusters" || true)"
  if [[ -z "${http_code}" || "${http_code}" == "000" ]]; then
    echo "ERROR: platform API at ${BASE_URL} does not answer (HTTP ${http_code:-none}) — environment not ready" >&2
    exit 1
  fi
  if [[ "${http_code}" == 5* ]]; then
    echo "ERROR: platform API at ${BASE_URL} returned HTTP ${http_code} — environment not ready" >&2
    exit 1
  fi
  echo "WARNING: no AWS credentials mounted — readiness check limited to the unsigned gateway probe (HTTP ${http_code})" >&2
fi

if [[ -r "${AWS_CONFIG_FILE}" ]]; then
  if ! aws configure export-credentials --profile rrp-customer --format process &>/dev/null; then
    echo "ERROR: customer credentials (rrp-customer) do not work — environment not ready" >&2
    exit 1
  fi
  # Account allowlisting is verified, not performed: before-suites.sh (sourced
  # by the runner in the rosa-seaplane checkout) performs the registration.
  customer_account_id="$(aws sts get-caller-identity --profile rrp-customer --query Account --output text)" || {
    echo "ERROR: could not resolve customer account — environment not ready" >&2
    exit 1
  }
  # Disable tracing for the allowlist probe: the response echoes account data.
  if ! AWS_PROFILE=rrp-rc awscurl --service execute-api --region "${AWS_DEFAULT_REGION}" --fail-with-body \
      -X GET "${BASE_URL}/api/v0/accounts/${customer_account_id}" -o /dev/null 2>/dev/null; then
    echo "NOTE: customer account not yet allowlisted — before-suites.sh will register it"
  fi
fi

# ---------------------------------------------------------------------------
# 5. Write e2e.env (plain KEY=value, no secrets).
# ---------------------------------------------------------------------------
cat > "${E2E_ENV}" <<EOF
E2E_SRC_API=${E2E_SRC_API}
E2E_SRC_ZOA=${E2E_SRC_ZOA}
E2E_SRC_ROSA_CLI=${E2E_SRC_ROSA_CLI}
BASE_URL=${BASE_URL}
RHOBS_API_URL=${RHOBS_API_URL:-}
ZOA_RC_API_URL=${ZOA_RC_API_URL:-}
ZOA_MC_API_URL=${ZOA_MC_API_URL:-}
ZOA_DEPLOYMENT_NAME=${ZOA_DEPLOYMENT_NAME:-}
CLUSTER_PREFIX=${CLUSTER_PREFIX}
OCP_IMAGE=${OCP_IMAGE}
AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}
EOF

echo "Wrote ${E2E_ENV}:"
cat "${E2E_ENV}"
