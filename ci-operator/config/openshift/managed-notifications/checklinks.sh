REPO_URL="https://github.com/openshift/managed-notifications/"
ARTIFACT_DIR="${ARTIFACTS:-/tmp/artifacts}"
mkdir -p "$ARTIFACT_DIR"
LOG_FILE="$ARTIFACT_DIR/build-log.log"
TEMP_FILE=$(mktemp -p "$ARTIFACT_DIR" broken_links_XXXXXX)
cd /go/src/github.com/openshift/managed-notifications || exit
grep -rEo "(http|https)://[a-zA-Z0-9./?=_-]*" . | sort -u | while read -r URL; do
    if [ "$(curl -o /dev/null -s -w '%{http_code}' "$URL")" != "200" ]; then
        echo "$URL" >> "$TEMP_FILE"
    fi
done
if [ -s "$TEMP_FILE" ]; then
    echo "Broken links detected:" | tee -a "$LOG_FILE"
    cat "$TEMP_FILE" | tee -a "$LOG_FILE"
    exit 1
else
    echo "No broken links detected." | tee -a "$LOG_FILE"
    exit 0
fi

