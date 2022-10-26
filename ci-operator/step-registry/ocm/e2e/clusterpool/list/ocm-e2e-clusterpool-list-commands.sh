#!/bin/bash

temp=$(mktemp -d -t ocm-XXXXX)
cd "$temp" || exit 1

echo "INFO Setting clusterpool list file"
LIST_FILE="$SHARED_DIR/$CLUSTERPOOL_LIST_FILE"
echo "     LIST_FILE: $LIST_FILE"

echo "INFO Copying make file"
echo "     MAKEFILE: $MAKEFILE"
cp "$MAKEFILE" ./Makefile

echo "INFO Setting location of oc and jq binarys for build harness"
OC=$(which oc)
JQ=$(which jq)
export OC
export JQ
if [[ -z "$OC" ]]; then
    echo "ERROR The oc command is not installed"
    exit 1
fi
if [[ -z "$JQ" ]]; then
    echo "ERROR The jq command is not installed"
    exit 1
fi

echo "INFO Getting list of all clusterpools in json format"
make clusterpool/list-clusterpools CLUSTERPOOL_LIST_ARGUMENTS=" -o json" > list.json
echo "INFO Saving clusterpool json file to artifact directory"
cp list.json "${ARTIFACT_DIR}/list.json"

echo "INFO Getting the names of all clusterpools"
jq -r '.items[].metadata.name' list.json > "${LIST_FILE}-all"
echo "INFO Getting the names of all clusterpools in a ready or standby state"
jq -r '.items[] | select(.status.standby + .status.ready > 0) | .metadata.name' list.json > "$LIST_FILE"
echo "INFO All clusterpools:"
cat "${LIST_FILE}-all"
echo "INFO All ready or standby clusterpools:"
cat "$LIST_FILE"
echo "     --- end ---"

echo "INFO Checking inclusion filter..."
if [[ -n "$CLUSTERPOOL_LIST_INCLUSION_FILTER" ]]; then
    echo "     CLUSTERPOOL_LIST_INCLUSION_FILTER: $CLUSTERPOOL_LIST_INCLUSION_FILTER"

    echo "INFO Applying inclusion filter"
    grep -e "$CLUSTERPOOL_LIST_INCLUSION_FILTER" "${LIST_FILE}" > "${LIST_FILE}.tmp" || true
    grep -e "$CLUSTERPOOL_LIST_INCLUSION_FILTER" "${LIST_FILE}-all" > "${LIST_FILE}-all.tmp" || true

    echo "INFO Clusterpool list after filtering:"
    cat "${LIST_FILE}-all.tmp"
    echo "INFO Clusterpool list in ready or standby after filtering:"
    cat "${LIST_FILE}.tmp"
    echo "     --- end ---"

    echo "INFO Number of clusterpools after inclusion filter:"
    echo "     ---$(wc -l < "${LIST_FILE}-all.tmp")---"
    echo "INFO Number of clusterpools in ready or standby after inclusion filter:"
    echo "     ---$(wc -l < "$LIST_FILE.tmp")---"

    echo "INFO Checking if any clusterpools are left..."
    if [[ $(wc -l < "${LIST_FILE}.tmp") == 0 ]]; then
        echo "WARNING No ready or standby clusterpools left after applying inclusion filter."
    fi
    if [[ $(wc -l < "${LIST_FILE}-all.tmp") == 0 ]]; then
        echo "ERROR No clusterpools left after applying inclusion filter."
        exit 1
    fi

    echo "INFO Updating list of clusterpools"
    mv "${LIST_FILE}-all.tmp" "${LIST_FILE}-all"
    mv "${LIST_FILE}.tmp" "$LIST_FILE"
else
    echo "     inclusion filter not provided"
fi

echo "INFO Checking exclusion filter"
if [[ -n "$CLUSTERPOOL_LIST_EXCLUSION_FILTER" ]]; then
    echo "     CLUSTERPOOL_LIST_EXCLUSION_FILTER: $CLUSTERPOOL_LIST_EXCLUSION_FILTER"

    echo "INFO Applying exclusion filter"
    grep -v -e "$CLUSTERPOOL_LIST_EXCLUSION_FILTER" "${LIST_FILE}" > "${LIST_FILE}.tmp" || true
    grep -v -e "$CLUSTERPOOL_LIST_EXCLUSION_FILTER" "${LIST_FILE}-all" > "${LIST_FILE}-all.tmp" || true

    echo "INFO Clusterpool list after filtering:"
    cat "${LIST_FILE}-all.tmp"
    echo "INFO Clusterpool list in ready or standby after filtering:"
    cat "${LIST_FILE}.tmp"
    echo "     --- end ---"

    echo "INFO Number of clusterpools after exclusion filter:"
    echo "     ---$(wc -l < "${LIST_FILE}-all.tmp")---"
    echo "INFO Number of clusterpools in ready or standby after exclusion filter:"
    echo "     ---$(wc -l < "$LIST_FILE.tmp")---"

    echo "INFO Checking if any clusterpools are left..."
    if [[ $(wc -l < "${LIST_FILE}.tmp") == 0 ]]; then
        echo "WARNING No ready or standby clusterpools left after applying exclusion filter."
    fi
    if [[ $(wc -l < "${LIST_FILE}-all.tmp") == 0 ]]; then
        echo "ERROR No clusterpools left after applying exclusion filter."
        exit 1
    fi

    echo "INFO Updating list of clusterpools"
    mv "${LIST_FILE}-all.tmp" "${LIST_FILE}-all"
    mv "${LIST_FILE}.tmp" "$LIST_FILE"
else
    echo "     exclusion filter not provided"
fi

echo "INFO All clusterpool list:"
cat "${LIST_FILE}-all"
echo "INFO Ready or standby clusterpool list:"
cat "$LIST_FILE"
echo "     --- end ---"

echo "INFO Verifying ready or standby clusterpool list..."
if [[ $(wc -l < "${LIST_FILE}") == 0 ]]; then
    echo "WARNING No ready or standby clusterpools left. Replacing the list with the list of all clusterpools."
    mv "${LIST_FILE}-all" "${LIST_FILE}"
else
    rm "${LIST_FILE}-all"
fi

echo "INFO Checking if list needs to be reordered"
echo "     CLUSTERPOOL_LIST_ORDER: $CLUSTERPOOL_LIST_ORDER"
case "$CLUSTERPOOL_LIST_ORDER" in
    "")
        echo "     CLUSTERPOOL_LIST_ORDER is empty"
        echo "     Will not change list order"
        ;;
    sort)
        echo "INFO Sorting clusterpool list"
        sort "$LIST_FILE" > "$LIST_FILE.tmp"

        echo "INFO Sorted clusterpool list:"
        cat "$LIST_FILE.tmp"
        echo "     --- end ---"

        echo "INFO Updating list of available clusterpools"
        mv "$LIST_FILE.tmp" "$LIST_FILE"
        ;;
    shuffle)
        echo "INFO Shuffling clusterpool list"
        shuf "$LIST_FILE" > "$LIST_FILE.tmp"

        echo "INFO Shuffled clusterpool list:"
        cat "$LIST_FILE.tmp"
        echo "     --- end ---"

        echo "INFO Updating list of available clusterpools"
        mv "$LIST_FILE.tmp" "$LIST_FILE"
        ;;
    *)
        echo "     Invalid CLUSTERPOOL_LIST_ORDER"
        echo "     Ignoring"
        ;;
esac

echo "INFO Final clusterpool list:"
cat "$LIST_FILE"
echo "     --- end ---"
