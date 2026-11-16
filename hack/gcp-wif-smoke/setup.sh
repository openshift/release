#!/usr/bin/env bash
# Create only the isolated build13 authentication smoke-test resources.
set -euo pipefail

: "${BUILD13_CONTEXT:?Set BUILD13_CONTEXT to an authenticated build13 oc context}"
PROJECT=openshift-ci-build-farm
POOL=build13-wif-smoke
GSA="build13-wif-smoke@${PROJECT}.iam.gserviceaccount.com"
NAMESPACE=wif-smoke
KSA=gcp-smoke
ISSUER=https://storage.googleapis.com/build13-oidc
SUBJECT="system:serviceaccount:${NAMESPACE}:${KSA}"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OUTPUT_DIR=${OUTPUT_DIR:-/tmp/build13-wif-smoke}
mkdir -p "$OUTPUT_DIR"

# Verify the selected cluster before changing Google Cloud resources.
oc --context="$BUILD13_CONTEXT" get --raw /.well-known/openid-configuration > "$OUTPUT_DIR/issuer.json"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["issuer"] == sys.argv[2], "context is not using the expected build13 issuer"' "$OUTPUT_DIR/issuer.json" "$ISSUER"
gcloud projects describe "$PROJECT" --format='value(projectNumber)' > "$OUTPUT_DIR/project-number"
PROJECT_NUMBER=$(cat "$OUTPUT_DIR/project-number")
if [[ "$PROJECT_NUMBER" != 263120870185 ]]; then
  echo 'Unexpected GCP project number; refusing to configure trust.' >&2
  exit 1
fi
PROVIDER="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/build13"
TOKEN_AUDIENCE="https://iam.googleapis.com/${PROVIDER}"
CONDITION="assertion.iss == '${ISSUER}' && assertion.sub == '${SUBJECT}'"
gcloud services enable iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com --project="$PROJECT"

existing=$(gcloud iam workload-identity-pools list --project="$PROJECT" --location=global --filter="name:/${POOL}" --format='value(name)')
if [[ -z "$existing" ]]; then
  gcloud iam workload-identity-pools create "$POOL" --project="$PROJECT" --location=global --display-name='Build13 isolated WIF smoke test'
fi
existing=$(gcloud iam service-accounts list --project="$PROJECT" --filter="email=${GSA}" --format='value(email)')
if [[ -z "$existing" ]]; then
  gcloud iam service-accounts create build13-wif-smoke --project="$PROJECT" --display-name='Build13 WIF smoke test (no resource roles)'
fi
existing=$(gcloud iam workload-identity-pools providers list --project="$PROJECT" --location=global --workload-identity-pool="$POOL" --format='value(name)')
if [[ -z "$existing" ]]; then
  gcloud iam workload-identity-pools providers create-oidc build13 --project="$PROJECT" --location=global --workload-identity-pool="$POOL" --issuer-uri="$ISSUER" --attribute-mapping='google.subject=assertion.sub' --attribute-condition="$CONDITION" --allowed-audiences="$TOKEN_AUDIENCE"
elif [[ "$existing" != "$PROVIDER" ]]; then
  echo 'The smoke-test pool contains unexpected providers; refusing to reuse it.' >&2
  exit 1
fi
gcloud iam workload-identity-pools providers describe build13 --project="$PROJECT" --location=global --workload-identity-pool="$POOL" --format=json > "$OUTPUT_DIR/provider.json"
python3 - "$OUTPUT_DIR/provider.json" "$ISSUER" "$CONDITION" "$TOKEN_AUDIENCE" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
assert not p.get("disabled", False), "provider is disabled"
assert p["oidc"]["issuerUri"] == sys.argv[2], "unexpected issuer"
assert p["attributeCondition"] == sys.argv[3], "unexpected trust condition"
assert p["attributeMapping"] == {"google.subject": "assertion.sub"}, "unexpected mapping"
assert p["oidc"]["allowedAudiences"] == [sys.argv[4]], "unexpected token audience"
PY
gcloud iam service-accounts add-iam-policy-binding "$GSA" --project="$PROJECT" --role=roles/iam.workloadIdentityUser --member="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/subject/${SUBJECT}" --quiet > /dev/null
gcloud iam workload-identity-pools create-cred-config "$PROVIDER" --service-account="$GSA" --credential-source-file=/var/run/wif/token --credential-source-type=text --output-file="$OUTPUT_DIR/external-account.json"
python3 "$SCRIPT_DIR/manifest.py" "$OUTPUT_DIR/external-account.json" > "$OUTPUT_DIR/smoke.json"
printf 'Prepared %s/smoke.json. No Kubernetes resources have been applied.\n' "$OUTPUT_DIR"
