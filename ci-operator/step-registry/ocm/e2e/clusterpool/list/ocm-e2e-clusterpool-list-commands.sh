#!/bin/bash

OUTPUT="$SHARED_DIR/$CLUSTERPOOL_LIST_FILE"

echo "OUTPUT=$OUTPUT"
echo "uid=$(id -u)"

temp=$(mktemp -d -t ocm-XXXXX)
echo "temp=$temp"
cd $temp || exit 1

cp "$MAKEFILE" ./Makefile

make -d clusterpool/list-clusterpools CLUSTERPOOL_LIST_ARGUMENTS=" -o json" > list.json
echo "list.json:"
cat list.json
echo "---"

jq -r '.items[] | select(.status.ready > 0) | .metadata.name' list.json > "$OUTPUT"
echo "$OUTPUT after jq:"
cat "$OUTPUT"
echo "---"

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
