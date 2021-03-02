#!/bin/bash

OUTPUT="$SHARED_DIR/$CLUSTERPOOL_LIST_FILE"

temp=$(mktemp -d -t ocm-XXXXX)
cd $temp || exit 1

cp "$MAKEFILE" ./Makefile

make clusterpool/list-clusterpools CLUSTERPOOL_LIST_ARGUMENTS=" -o json" > >(tee list.json ${ARTIFACT_DIR}/list.json)

jq -r '.items[] | select(.status.ready > 0) | .metadata.name' list.json > >(tee "$OUTPUT" "${ARTIFACT_DIR}/$CLUSTERPOOL_LIST_FILE")

if [[ -n "$CLUSTERPOOL_LIST_FILTER" ]]; then
    grep -v -e "$CLUSTERPOOL_LIST_FILTER" "$OUTPUT" > "$OUTPUT.tmp"
    mv "$OUTPUT.tmp" "$OUTPUT"
fi
echo "$OUTPUT after grep:"
cat "$OUTPUT"
echo "---"

case "$CLUSTERPOOL_LIST_ORDER" in
    sort)
        sort "$OUTPUT" > "$OUTPUT.tmp"
        mv "$OUTPUT.tmp" "$OUTPUT"
        ;;
    shuffle)
        shuf "$OUTPUT" > "$OUTPUT.tmp"
        mv "$OUTPUT.tmp" "$OUTPUT"
        ;;
esac

echo "Cluster pools"
cat "$OUTPUT"
