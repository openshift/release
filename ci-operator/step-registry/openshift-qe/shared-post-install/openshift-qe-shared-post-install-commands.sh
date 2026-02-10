#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Create shared retry library for use by subsequent steps
cat > ${SHARED_DIR}/retry-lib.sh << 'RETRY_EOF'
#!/bin/bash

# Retry function for git clone operations
# Usage: retry_git_clone <repo_url> [git clone options...]
retry_git_clone() {
    local max_retries=3
    local retry_delay=5
    local attempt=1

    while [ $attempt -le $max_retries ]; do
        echo "Attempt $attempt of $max_retries: git clone $@"
        if git clone "$@"; then
            echo "git clone succeeded on attempt $attempt"
            return 0
        fi
        echo "git clone failed on attempt $attempt"
        if [ $attempt -lt $max_retries ]; then
            echo "Waiting ${retry_delay} seconds before retry..."
            sleep $retry_delay
            retry_delay=$((retry_delay * 2))
        fi
        attempt=$((attempt + 1))
    done

    echo "git clone failed after $max_retries attempts"
    return 1
}
RETRY_EOF

echo "Created retry library at ${SHARED_DIR}/retry-lib.sh"
