#!/bin/bash

OUTPUT="$SHARED_DIR/$CLUSTERPOOL_LIST_FILE"

echo "OUTPUT=$OUTPUT"
echo "uid=$(id -u)"

temp=$(mktemp)
cd $temp || exit 1

cp "$MAKEFILE" ./Makefile

make clusterpool/list-clusterpools CLUSTERPOOL_LIST_ARGUMENTS=" -o json" \
    | jq -r '.items[] | select(.status.ready > 0) | .metadata.name' > "$OUTPUT"

if [[ -n "$CLUSTERPOOL_LIST_FILTER" ]]; then
    grep -v -e "$CLUSTERPOOL_LIST_FILTER" "$OUTPUT" > "$OUTPUT.tmp"
    mv "$OUTPUT.tmp" "$OUTPUT"
fi

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
