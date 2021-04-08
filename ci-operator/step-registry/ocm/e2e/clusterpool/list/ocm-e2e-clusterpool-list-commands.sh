#!/bin/bash

temp=$(mktemp -d -t ocm-XXXXX)
cd $temp || exit 1

OUTPUT="$SHARED_DIR/$CLUSTERPOOL_LIST_FILE"

cp "$MAKEFILE" ./Makefile

make clusterpool/list-clusterpools CLUSTERPOOL_LIST_ARGUMENTS=" -o json" > >(tee list.json ${ARTIFACT_DIR}/list.json)

jq -r '.items[] | select(.status.ready > 0) | .metadata.name' list.json > >(tee "$OUTPUT" "${ARTIFACT_DIR}/$CLUSTERPOOL_LIST_FILE")

if [[ -n "$CLUSTERPOOL_LIST_INCLUSION_FILTER" ]]; then
    grep -e "$CLUSTERPOOL_LIST_INCLUSION_FILTER" "$OUTPUT" > "$OUTPUT.tmp"
    if [[ $(cat "$OUTPUT.tmp" | wc -l) == 0 ]]; then
        echo "ERROR No clusters left after applying inclusion filter."
        echo "Inclusion filter: $CLUSTERPOOL_LIST_INCLUSION_FILTER"
        echo "Original clusters:"
        cat "$OUTPUT"
        exit 1
    fi
    mv "$OUTPUT.tmp" "$OUTPUT"
fi

if [[ -n "$CLUSTERPOOL_LIST_EXCLUSION_FILTER" ]]; then
    grep -v -e "$CLUSTERPOOL_LIST_EXCLUSION_FILTER" "$OUTPUT" > "$OUTPUT.tmp"
    if [[ $(cat "$OUTPUT.tmp" | wc -l) == 0 ]]; then
        echo "ERROR No clusters left after applying exclusion filter."
        echo "Exclusion filter: $CLUSTERPOOL_LIST_EXCLUSION_FILTER"
        echo "Original clusters:"
        cat "$OUTPUT"
        exit 1
    fi
    mv "$OUTPUT.tmp" "$OUTPUT"
fi

echo "$OUTPUT after filtering:"
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
