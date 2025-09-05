#!/bin/bash
set -euo pipefail

# Read credentials from mounted secrets (set both if present)
GEM_KEY=""; if [ -d /var/run/secrets/gemini ]; then for f in /var/run/secrets/gemini/*; do if [ -f "$f" ]; then GEM_KEY="$(cat "$f")"; break; fi; done; fi
VJSON=""; if [ -d /var/run/secrets/vertex ]; then VJSON="$(ls /var/run/secrets/vertex/service_account 2>/dev/null | head -n1)" || true; fi
if [ -n "$GEM_KEY" ]; then export GEMINI_API_KEY="$GEM_KEY"; fi
if [ -n "$VJSON" ]; then export GOOGLE_APPLICATION_CREDENTIALS="$VJSON"; fi

# Ensure ocm is available
export PATH="${HOME}/.local/bin:${PATH}"
if ! command -v ocm >/dev/null 2>&1; then \
  mkdir -p "${HOME}/.local/bin" && \
  curl -sSL -o "${HOME}/.local/bin/ocm" "https://github.com/openshift-online/ocm-cli/releases/latest/download/ocm-linux-amd64" && \
  chmod +x "${HOME}/.local/bin/ocm"; \
fi

# OCM auth: support either raw JWT token or client credentials
OCM_TOKEN_VALUE="${OCM_TOKEN:-}" || true
if [ -z "$OCM_TOKEN_VALUE" ] && [ -d /var/run/secrets/sso-ci ]; then \
  FIRST_FILE=$(ls -1 /var/run/secrets/sso-ci/* 2>/dev/null | head -n1 || true); \
  if [ -n "$FIRST_FILE" ] && [ -f "$FIRST_FILE" ]; then OCM_TOKEN_VALUE="$(cat "$FIRST_FILE" 2>/dev/null || true)"; fi; \
fi
# If token looks like a JWT (has two dots), login with --token; otherwise try client credentials
if [ -n "$OCM_TOKEN_VALUE" ] && echo "$OCM_TOKEN_VALUE" | grep -qE '^[^\.]+\.[^\.]+\.[^\.]+$'; then \
  ocm login --token "$OCM_TOKEN_VALUE" >/dev/null 2>&1 || true; \
else \
  CID_FILE=$(ls -1 /var/run/secrets/sso-ci/*id* 2>/dev/null | head -n1 || true); \
  CSEC_FILE=$(ls -1 /var/run/secrets/sso-ci/*secret* 2>/dev/null | head -n1 || true); \
  CLIENT_ID=""; CLIENT_SECRET=""; \
  if [ -n "$CID_FILE" ] && [ -f "$CID_FILE" ]; then CLIENT_ID="$(cat "$CID_FILE" 2>/dev/null || true)"; fi; \
  if [ -n "$CSEC_FILE" ] && [ -f "$CSEC_FILE" ]; then CLIENT_SECRET="$(cat "$CSEC_FILE" 2>/dev/null || true)"; fi; \
  if [ -n "$CLIENT_ID" ] && [ -n "$CLIENT_SECRET" ]; then \
    ocm login --client-id "$CLIENT_ID" --client-secret "$CLIENT_SECRET" >/dev/null 2>&1 || true; \
  fi; \
fi
# Obtain access token if possible
if [ -z "${OCM_TOKEN:-}" ]; then \
  export OCM_TOKEN="$(ocm token 2>/dev/null || true)"; \
fi

# Repo prep
git submodule update --init --recursive
# .env setup
if [ ! -f .env ] && [ -f .env.template ]; then cp .env.template .env; fi
if [ -n "${GEMINI_API_KEY:-}" ]; then \
  if grep -q '^GEMINI_API_KEY=' .env 2>/dev/null; then sed -i "s/^GEMINI_API_KEY=.*/GEMINI_API_KEY=${GEMINI_API_KEY//\//\\/}/" .env; else echo "GEMINI_API_KEY=${GEMINI_API_KEY}" >> .env; fi; \
fi
# Do not write GOOGLE_APPLICATION_CREDENTIALS into .env; pod uses a fixed in-container path

# Ensure config dir exists
mkdir -p config

# If Vertex creds path provided, copy it to the path expected by pod subPath mount
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && [ -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]; then \
  cp -f "${GOOGLE_APPLICATION_CREDENTIALS}" config/vertex-credentials.json; \
fi

# Podman auth
if [ -f /etc/pull-secret/.dockerconfigjson ]; then mkdir -p ${HOME}/.config/containers && cp /etc/pull-secret/.dockerconfigjson ${HOME}/.config/containers/auth.json; fi

# Generate config
make generate || echo "make generate failed or interactive; proceeding with shim"
if [ -n "${GEMINI_API_KEY:-}" ] && [ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then \
  mkdir -p config && [ -s config/vertex-credentials.json ] || printf '{}' > config/vertex-credentials.json; \
fi

# Run workflow
# Configure nested podman/buildah for CI container
export BUILDAH_ISOLATION=chroot
export STORAGE_DRIVER=vfs
make build-images
make run &

# Readiness wait with timeout (up to 90s)
BASE_URL="http://localhost:8090"
for i in $(seq 1 18); do \
  if curl -sS --max-time 5 "${BASE_URL}/healthz" >/dev/null 2>&1; then echo "service ready"; break; fi; \
  sleep 5; \
  if [ "$i" -eq 18 ]; then echo "service failed to become ready in time"; fi; \
done

# Non-interactive sample query (guarded by token and readiness)
if [ -n "${OCM_TOKEN:-}" ]; then \
  MODELS_JSON=$(curl -sS --max-time 10 -H "Authorization: Bearer ${OCM_TOKEN}" "${BASE_URL}/v1/models" || true); \
  SEL=$(echo "$MODELS_JSON" | jq -r '.models[] | select(.model_type=="llm") | "\(.provider_resource_id)|\(.provider_id)"' | head -n1 || true); \
  MODEL_NAME=$(echo "$SEL" | cut -d'|' -f1); MODEL_PROVIDER=$(echo "$SEL" | cut -d'|' -f2); \
  if [ -n "$MODEL_NAME" ] && [ -n "$MODEL_PROVIDER" ]; then \
    curl -sS --max-time 15 -H "Authorization: Bearer ${OCM_TOKEN}" "${BASE_URL}/v1/query" --json '{"model":"'"$MODEL_NAME"'","provider":"'"$MODEL_PROVIDER"'","query":"hello"}' >/dev/null || true; \
  fi; \
fi

# Proceed to evaluation
make test-eval 

# Stop the pod
make stop